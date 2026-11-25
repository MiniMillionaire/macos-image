#!/usr/bin/env python3
import importlib.util
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

path = Path(__file__).resolve().parents[1] / "scripts/configure-screen-sharing-policy.py"
spec = importlib.util.spec_from_file_location("sharing_policy", path)
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


class ScreenSharingPolicyTests(unittest.TestCase):
    def test_failed_unmount_preserves_guest_files_and_unrelated_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            image = root / "image"
            image.mkdir()
            (image / "disk.img").touch()
            volume = root / "mounted"
            volume.mkdir()
            marker = volume / "private/var/db/.AppleSetupDone"
            marker.parent.mkdir(parents=True)
            marker.touch()
            document = volume / "user-document"
            document.write_text("Keep this guest data")
            privacy = volume / "Library/Application Support/com.apple.TCC/SiteOverrides.plist"
            privacy.parent.mkdir(parents=True)
            unrelated = {"Identifier": "example.denied", "Allowed": False}
            privacy.write_bytes(plistlib.dumps({"Services": {"ScreenCapture": [unrelated], "Other": [unrelated]}}))
            ejected = []

            def command(*arguments):
                if arguments[0].endswith("hdiutil"):
                    return plistlib.dumps({"images": []})
                action = arguments[1]
                if action == "image":
                    return b"/dev/disk90\n"
                if action == "list":
                    return plistlib.dumps({"AllDisksAndPartitions": [{"Partitions": [
                        {"Content": "Apple_APFS", "DeviceIdentifier": "disk90s2"}]}]})
                if action == "apfs":
                    return plistlib.dumps({"Containers": [{"PhysicalStores": [{"DeviceIdentifier": "disk90s2"}],
                        "Volumes": [{"DeviceIdentifier": "disk91s1", "Roles": ["Data"]}]}]})
                if action == "mount":
                    return b""
                if action == "unmount":
                    raise RuntimeError("Guest volume remains mounted")
                if action == "eject":
                    ejected.append(arguments[-1])
                    return b""
                self.fail(f"Unexpected command: {arguments}")

            with patch.object(policy.os, "geteuid", return_value=0), \
                    patch.object(policy.os, "chown"), patch.object(policy.os, "fchown"), \
                    patch.object(policy.tempfile, "mkdtemp", return_value=str(volume)), \
                    patch.object(policy.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, b"")), \
                    patch.object(policy, "command", side_effect=command):
                with self.assertRaisesRegex(RuntimeError, "Guest volume remains mounted"):
                    policy.configure(image)

            self.assertEqual(document.read_text(), "Keep this guest data")
            self.assertTrue(marker.is_file())
            self.assertEqual(ejected, ["/dev/disk90"])
            services = plistlib.loads(privacy.read_bytes())["Services"]
            self.assertEqual(services["Other"], [unrelated])
            self.assertIn(unrelated, services["ScreenCapture"])
            for service in ("ScreenCapture", "PostEvent"):
                granted = [entry for entry in services[service] if entry.get("Allowed") is True]
                self.assertEqual(len(granted), 1)
                self.assertEqual(granted[0]["Identifier"], "com.apple.screensharing.agent")
                self.assertEqual(granted[0]["CodeRequirement"],
                                 'identifier "com.apple.screensharing.agent" and anchor apple')


if __name__ == "__main__":
    unittest.main()
