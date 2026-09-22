#!/usr/bin/env python3
import ctypes
import hashlib
import json
import os
from pathlib import Path
import signal
import stat
import struct
import subprocess

FAT = {
    b"\xca\xfe\xba\xbe": (">", False),
    b"\xbe\xba\xfe\xca": ("<", False),
    b"\xca\xfe\xba\xbf": (">", True),
    b"\xbf\xba\xfe\xca": ("<", True),
}
THIN = {
    b"\xfe\xed\xfa\xce": ">",
    b"\xce\xfa\xed\xfe": "<",
    b"\xfe\xed\xfa\xcf": ">",
    b"\xcf\xfa\xed\xfe": "<",
}
ARM64 = 0x0100000C
INTEL = {7, 0x01000007}
COMPRESSED = 0x20
COPYFILE_ACL = 1
MAX_ARCHES = 128


def command(arguments, check=True, timeout=60):
    result = subprocess.run(
        list(map(str, arguments)), capture_output=True, timeout=timeout
    )
    if check and result.returncode:
        message = result.stderr.decode(errors="replace")[-1200:]
        raise RuntimeError(f"{arguments}: {message}")
    return result


def sha256(path, offset=0, size=None):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        stream.seek(offset)
        while size is None or size:
            block = stream.read(
                1024 * 1024 if size is None else min(size, 1024 * 1024)
            )
            if not block:
                if size:
                    raise ValueError(f"Truncated slice: {path}")
                break
            digest.update(block)
            if size is not None:
                size -= len(block)
    return digest.hexdigest()


def slices(path):
    size = path.stat().st_size
    with path.open("rb") as stream:
        header = stream.read(8)
        if header[:4] in THIN:
            cpu, subtype = struct.unpack(THIN[header[:4]] + "ii", header[4:] + stream.read(4))
            return [{"cpu": cpu, "subtype": subtype, "offset": 0, "size": size}]
        if header[:4] not in FAT:
            return []
        order, wide = FAT[header[:4]]
        count = struct.unpack(order + "I", header[4:])[0]
        if not 1 <= count <= MAX_ARCHES:
            raise ValueError(f"Invalid architecture count: {path}")
        entry = struct.Struct(order + ("iiQQII" if wide else "iiIII"))
        table_end = 8 + count * entry.size
        if table_end > size:
            raise ValueError(f"Truncated architecture table: {path}")
        table = stream.read(count * entry.size)
        result = []
        for index in range(count):
            cpu, subtype, offset, length, alignment, *_ = entry.unpack_from(
                table, index * entry.size
            )
            if length <= 0 or offset < table_end or offset + length > size:
                raise ValueError(f"Invalid architecture slice: {path}")
            if alignment > (63 if wide else 31) or offset % (1 << alignment):
                raise ValueError(f"Invalid architecture alignment: {path}")
            result.append(
                {"cpu": cpu, "subtype": subtype, "offset": offset, "size": length}
            )
        end = table_end
        for item in sorted(result, key=lambda value: value["offset"]):
            if item["offset"] < end:
                raise ValueError(f"Overlapping architecture slices: {path}")
            end = item["offset"] + item["size"]
        return result


def retained(path):
    return [
        (item["cpu"], item["subtype"], item["size"], sha256(path, item["offset"], item["size"]))
        for item in slices(path)
        if item["cpu"] == ARM64
    ]


def signature(path):
    result = command(
        [
            "/usr/bin/codesign",
            "--verify",
            "--strict",
            "--all-architectures",
            "--ignore-resources",
            path,
        ],
        check=False,
    )
    return {
        "exit": result.returncode,
        "stderr": result.stderr.decode(errors="replace")[-1000:],
    }


def preserve_metadata(source, target, original):
    library = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
    library.copyfile.argtypes = [
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_void_p,
        ctypes.c_uint32,
    ]
    library.copyfile.restype = ctypes.c_int
    if library.copyfile(os.fsencode(source), os.fsencode(target), None, COPYFILE_ACL):
        raise OSError(ctypes.get_errno(), "Cannot preserve ACL")
    names = command(["/usr/bin/xattr", source]).stdout.decode().splitlines()
    for name in names:
        if name == "com.apple.decmpfs" or (
            name == "com.apple.ResourceFork" and original.st_flags & COMPRESSED
        ):
            continue
        value = command(["/usr/bin/xattr", "-px", name, source]).stdout.decode()
        command(["/usr/bin/xattr", "-wx", name, value, target])
    os.chown(target, original.st_uid, original.st_gid)
    os.chmod(target, stat.S_IMODE(original.st_mode))
    os.utime(target, ns=(original.st_atime_ns, original.st_mtime_ns))
    os.chflags(
        target,
        (original.st_flags & ~COMPRESSED) | (target.stat().st_flags & COMPRESSED),
    )


def inventory(roots):
    files = {}
    for root in roots:
        device = root.stat().st_dev
        for base, directories, names in os.walk(root, followlinks=False):
            base = Path(base)
            kept = []
            for name in sorted(directories):
                path = base / name
                info = path.lstat()
                if stat.S_ISDIR(info.st_mode) and info.st_dev == device:
                    kept.append(name)
            directories[:] = kept
            for name in sorted(names):
                path = base / name
                info = path.lstat()
                if not stat.S_ISREG(info.st_mode) or info.st_dev != device:
                    continue
                key = (info.st_dev, info.st_ino)
                if key in files:
                    if files[key] is not None:
                        files[key]["paths"].append(path)
                    continue
                try:
                    architectures = slices(path)
                except (ValueError, struct.error):
                    files[key] = None
                    continue
                if not architectures:
                    files[key] = None
                    continue
                files[key] = {
                    "paths": [path],
                    "architectures": architectures,
                    "hardlinks": info.st_nlink,
                }
    records = []
    for value in (item for item in files.values() if item is not None):
        architectures = value["architectures"]
        if not architectures:
            continue
        cpus = {item["cpu"] for item in architectures}
        if ARM64 in cpus and cpus & INTEL:
            value["category"] = "mixed"
        elif cpus and cpus <= INTEL:
            value["category"] = "x86_only"
        else:
            continue
        value["paths"].sort(key=str)
        records.append(value)
    return sorted(records, key=lambda value: str(value["paths"][0]))


def thin(record, number):
    paths = record["paths"]
    source = paths[0]
    original = source.lstat()
    if original.st_nlink != len(paths) or record["hardlinks"] != len(paths):
        return "incomplete_hardlinks", 0, 0
    before = original.st_blocks * 512
    expected = retained(source)
    arches = command(["/usr/bin/lipo", "-archs", source]).stdout.decode().split()
    removals = [value for value in arches if value in {"i386", "x86_64", "x86_64h"}]
    if not removals or any(
        not value.startswith("arm64") and value not in removals for value in arches
    ):
        return "unsupported_architectures", 0, 0
    old_signature = signature(source)
    prefix = f".macos-image-slim-{os.getpid()}-{number}"
    uncompressed = source.with_name(prefix + "-thin")
    compressed = source.with_name(prefix + "-compressed")
    backup = source.with_name(prefix + "-original")
    links = [source.with_name(prefix + f"-link-{index}") for index in range(len(paths))]
    temporary = [uncompressed, compressed, backup, *links]
    if any(path.exists() for path in temporary):
        raise RuntimeError(f"Temporary path already exists near {source}")
    committed = False
    try:
        arguments = ["/usr/bin/lipo", source]
        for architecture in removals:
            arguments.extend(["-remove", architecture])
        command([*arguments, "-output", uncompressed])
        if retained(uncompressed) != expected:
            raise RuntimeError(f"Retained architecture changed: {source}")
        command(["/usr/bin/ditto", "--hfsCompression", "--noclone", uncompressed, compressed])
        if original.st_flags & COMPRESSED and not compressed.stat().st_flags & COMPRESSED:
            return "compression_not_preserved", 0, 0
        if compressed.stat().st_blocks * 512 >= before:
            return "allocation_not_reduced", 0, 0
        new_signature = signature(compressed)
        if (
            new_signature["exit"] != old_signature["exit"]
            and "invalid Info.plist" not in new_signature["stderr"]
        ):
            return "signature_changed", 0, 0
        preserve_metadata(source, compressed, original)
        for link in links:
            os.link(compressed, link)
        os.link(source, backup)
        committed = True
        for link, destination in zip(links, paths):
            os.replace(link, destination)
        compressed.unlink()
        if signature(source)["exit"] != old_signature["exit"]:
            for link, destination in zip(links, paths):
                os.link(backup, link)
                os.replace(link, destination)
            backup.unlink()
            committed = False
            return "installed_signature_changed", 0, 0
        backup.unlink()
        installed = source.stat()
        if installed.st_nlink != len(paths) or any(
            path.stat().st_ino != installed.st_ino for path in paths
        ):
            raise RuntimeError(f"Hardlinks changed: {source}")
        if retained(source) != expected:
            raise RuntimeError(f"Installed architecture changed: {source}")
        return "changed", before, installed.st_blocks * 512
    finally:
        if not committed:
            for path in links:
                if path.exists():
                    path.unlink()
        for path in (uncompressed, compressed):
            if path.exists():
                path.unlink()


def remove_x86_only(record):
    paths = record["paths"]
    info = paths[0].lstat()
    if info.st_nlink != len(paths) or record["hardlinks"] != len(paths):
        return 0
    allocated = info.st_blocks * 512
    for path in paths:
        path.unlink()
    return allocated


def main():
    signal.alarm(90 * 60)
    if os.geteuid() != 0:
        raise SystemExit("root is required")
    username = os.environ["GUEST_USERNAME"]
    version = os.environ["XCODE_VERSION"]
    roots = [
        Path(f"/Applications/Xcode_{version}.app"),
        Path("/opt/homebrew"),
        Path(f"/Users/{username}/flutter"),
        Path(f"/Users/{username}/android-sdk"),
        Path(f"/Users/{username}/.local/share/mise"),
    ]
    if any(not path.is_dir() or path.is_symlink() for path in roots):
        raise SystemExit("slim Xcode roots are incomplete")
    records = inventory(roots)
    changed = 0
    before = 0
    after = 0
    skipped = {}
    for number, record in enumerate(
        value for value in records if value["category"] == "mixed"
    ):
        status, original, retained_bytes = thin(record, number)
        if status == "changed":
            changed += 1
            before += original
            after += retained_bytes
        else:
            skipped[status] = skipped.get(status, 0) + 1
    removed = 0
    removed_bytes = 0
    for record in (value for value in records if value["category"] == "x86_only"):
        reclaimed = remove_x86_only(record)
        if reclaimed:
            removed += 1
            removed_bytes += reclaimed
    remaining = inventory(roots)
    x86_only = [value for value in remaining if value["category"] == "x86_only"]
    if x86_only:
        raise SystemExit(f"x86-only files remain: {x86_only[0]['paths'][0]}")
    result = {
        "changed": changed,
        "removed": removed,
        "before_allocated": before,
        "after_allocated": after,
        "removed_allocated": removed_bytes,
        "retained_mixed": sum(value["category"] == "mixed" for value in remaining),
        "skipped": skipped,
    }
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
