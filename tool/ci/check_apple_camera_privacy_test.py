import plistlib
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def read_plist(path):
    with (ROOT / path).open("rb") as source:
        return plistlib.load(source)


class AppleCameraPrivacyTest(unittest.TestCase):
    def test_ios_native_capture_usage_descriptions(self):
        plist = read_plist("ios/Runner/Info.plist")
        for key in ("NSCameraUsageDescription", "NSMicrophoneUsageDescription"):
            with self.subTest(key=key):
                self.assertIsInstance(plist.get(key), str)
                self.assertTrue(plist[key].strip())

    def test_macos_camera_only_usage_description(self):
        plist = read_plist("macos/Runner/Info.plist")
        self.assertIsInstance(plist.get("NSCameraUsageDescription"), str)
        self.assertTrue(plist["NSCameraUsageDescription"].strip())
        self.assertNotIn("NSMicrophoneUsageDescription", plist)

    def test_macos_camera_only_entitlements(self):
        for configuration in ("DebugProfile", "Release"):
            with self.subTest(configuration=configuration):
                plist = read_plist(f"macos/Runner/{configuration}.entitlements")
                self.assertIs(plist.get("com.apple.security.app-sandbox"), True)
                self.assertIs(plist.get("com.apple.security.device.camera"), True)
                self.assertNotIn("com.apple.security.device.audio-input", plist)


if __name__ == "__main__":
    unittest.main()
