#!/usr/bin/env python3
import argparse
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def command(*arguments):
    return subprocess.check_output(arguments, timeout=120)


def configure(image):
    require(os.geteuid() == 0, "Administrator privileges are required")
    disk = image / "disk.img"
    require(image.resolve() == image and disk.is_file() and not disk.is_symlink(),
            "Expected a local raw image directory")
    opened = subprocess.run(["/usr/sbin/lsof", "-t", str(disk)], capture_output=True, timeout=30)
    require(opened.returncode == 1 and not opened.stdout.strip(), "Image disk is open or its usage is unknown")
    images = plistlib.loads(command("/usr/bin/hdiutil", "info", "-plist"))["images"]
    require(disk not in {Path(item["image-path"]).resolve() for item in images}, "Image disk is attached")
    attachment = command("/usr/sbin/diskutil", "image", "attach", "--noMount", str(disk)).decode()
    whole = attachment.splitlines()[0].split()[0]
    require(re.fullmatch(r"/dev/disk[0-9]+", whole), "Cannot identify the attached image")
    try:
        layout = plistlib.loads(command("/usr/sbin/diskutil", "list", "-plist", whole))
        stores = [item["DeviceIdentifier"] for item in layout["AllDisksAndPartitions"][0]["Partitions"]
                  if item.get("Content") == "Apple_APFS"]
        require(len(stores) == 1, "Expected one main APFS store")
        containers = plistlib.loads(command("/usr/sbin/diskutil", "apfs", "list", "-plist"))["Containers"]
        matches = [item for item in containers
                   if stores[0] in {store["DeviceIdentifier"] for store in item["PhysicalStores"]}]
        require(len(matches) == 1, "Expected one image container")
        volumes = [item["DeviceIdentifier"] for item in matches[0]["Volumes"] if "Data" in item.get("Roles", [])]
        require(len(volumes) == 1 and re.fullmatch(r"disk[0-9]+s[0-9]+", volumes[0]), "Expected one Data volume")
        directory = tempfile.mkdtemp(prefix="macos-image-sharing-")
        mounted = False
        try:
            command("/usr/sbin/diskutil", "mount", "-mountOptions", "nobrowse,noowners",
                    "-mountPoint", directory, volumes[0])
            mounted = True
            try:
                data = Path(directory).resolve()
                require((data / "private/var/db/.AppleSetupDone").is_file(), "Guest setup is incomplete")
                parent = data / "Library/Application Support/com.apple.TCC"
                require(parent.resolve() == parent, "Privacy policy directory contains a symlink")
                parent.mkdir(parents=True, exist_ok=True)
                policy = parent / "SiteOverrides.plist"
                require(not policy.is_symlink() and (not policy.exists() or policy.is_file()),
                        "Privacy policy is not a regular file")
                values = plistlib.loads(policy.read_bytes()) if policy.exists() else {}
                require(isinstance(values, dict), "Invalid privacy policy")
                services = values.setdefault("Services", {})
                require(isinstance(services, dict), "Invalid privacy services")
                for service in ("ScreenCapture", "PostEvent"):
                    entries = services.get(service, [])
                    require(isinstance(entries, list) and all(isinstance(item, dict) for item in entries),
                            "Invalid privacy service entries")
                    identity = "com.apple.screensharing.agent"
                    services[service] = [item for item in entries if item.get("Identifier") != identity] + [{
                        "Allowed": True, "Identifier": identity, "IdentifierType": "bundleID",
                        "CodeRequirement": 'identifier "com.apple.screensharing.agent" and anchor apple',
                    }]
                temporary = None
                try:
                    with tempfile.NamedTemporaryFile(dir=parent, delete=False) as stream:
                        temporary = Path(stream.name)
                        stream.write(plistlib.dumps(values))
                        os.fchmod(stream.fileno(), 0o644)
                        os.fchown(stream.fileno(), 0, 0)
                    os.replace(temporary, policy)
                finally:
                    if temporary is not None:
                        temporary.unlink(missing_ok=True)
                os.chown(parent, 0, 0)
                os.chmod(parent, 0o755)
                require(plistlib.loads(policy.read_bytes()) == values, "Privacy policy readback differs")
            finally:
                command("/usr/sbin/diskutil", "unmount", volumes[0])
                mounted = False
        finally:
            if not mounted:
                Path(directory).rmdir()
    finally:
        command("/usr/sbin/diskutil", "eject", whole)
    print("Configured guest Screen Sharing capture and input permissions")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Configure Screen Sharing privacy policy on a stopped image.")
    parser.add_argument("image", type=Path)
    configure(parser.parse_args().image)
