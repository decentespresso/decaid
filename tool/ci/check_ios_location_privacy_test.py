import contextlib
import io
import plistlib
import tempfile
import unittest
from pathlib import Path

from check_ios_location_privacy import (
    DEPRECATED_KEY,
    REQUIRED_KEYS,
    PrivacyCheckError,
    main,
    validate_plist,
)


ROOT = Path(__file__).resolve().parents[2]
SOURCE_PLIST = ROOT / "ios" / "Runner" / "Info.plist"
DESCRIPTION = (
    "Decaid uses a networking library to report its local Wi-Fi address for "
    "access to its interface and API on your local network. The library "
    "references location services; Decaid does not collect or track your "
    "location."
)


def write_plist(directory, value, binary=False):
    path = Path(directory) / ("Info-binary.plist" if binary else "Info.plist")
    with path.open("wb") as destination:
        plistlib.dump(value, destination, fmt=plistlib.FMT_BINARY if binary else plistlib.FMT_XML)
    return path


class IOSLocationPrivacyTest(unittest.TestCase):
    def valid_plist(self):
        return {
            "NSLocationWhenInUseUsageDescription": DESCRIPTION,
            "NSLocationAlwaysAndWhenInUseUsageDescription": DESCRIPTION,
        }

    def test_source_plist_has_required_location_declarations(self):
        validate_plist(SOURCE_PLIST)

    def test_valid_xml_and_binary_plists(self):
        with tempfile.TemporaryDirectory() as directory:
            for binary in (False, True):
                with self.subTest(binary=binary):
                    validate_plist(write_plist(directory, self.valid_plist(), binary))

    def test_missing_file_fails_closed_without_source_fallback(self):
        with tempfile.TemporaryDirectory() as directory:
            missing = Path(directory) / "Runner.app" / "Info.plist"
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr):
                result = main([str(missing)])
            self.assertEqual(result, 1)
            self.assertIn("plist not found", stderr.getvalue())

    def test_invalid_plist_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Info.plist"
            path.write_bytes(b"not a plist")
            with self.assertRaises(PrivacyCheckError):
                validate_plist(path)

    def test_non_dictionary_root_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            path = write_plist(directory, ["not", "a", "dictionary"])
            with self.assertRaisesRegex(PrivacyCheckError, "root must be a dictionary"):
                validate_plist(path)

    def test_each_required_key_is_checked(self):
        for key in REQUIRED_KEYS:
            with self.subTest(key=key), tempfile.TemporaryDirectory() as directory:
                plist = self.valid_plist()
                del plist[key]
                with self.assertRaisesRegex(PrivacyCheckError, key):
                    validate_plist(write_plist(directory, plist))

    def test_required_values_must_be_nonempty_strings(self):
        for value in ("", "   ", 123, True):
            for key in REQUIRED_KEYS:
                with self.subTest(key=key, value=repr(value)), tempfile.TemporaryDirectory() as directory:
                    plist = self.valid_plist()
                    plist[key] = value
                    with self.assertRaisesRegex(PrivacyCheckError, key):
                        validate_plist(write_plist(directory, plist))

    def test_generic_placeholders_are_rejected(self):
        for value in ("TODO", "placeholder", "Your description here", "replace me"):
            for key in REQUIRED_KEYS:
                with self.subTest(key=key, value=value), tempfile.TemporaryDirectory() as directory:
                    plist = self.valid_plist()
                    plist[key] = value
                    with self.assertRaisesRegex(PrivacyCheckError, "placeholder"):
                        validate_plist(write_plist(directory, plist))

    def test_deprecated_location_key_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            plist = self.valid_plist()
            plist[DEPRECATED_KEY] = "Legacy location description"
            with self.assertRaisesRegex(PrivacyCheckError, DEPRECATED_KEY):
                validate_plist(write_plist(directory, plist))


if __name__ == "__main__":
    unittest.main()
