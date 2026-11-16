#!/usr/bin/env python3
"""Validate iOS location purpose declarations in an Info.plist."""

import argparse
import plistlib
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SOURCE_PLIST = ROOT / "ios" / "Runner" / "Info.plist"
REQUIRED_KEYS = (
    "NSLocationWhenInUseUsageDescription",
    "NSLocationAlwaysAndWhenInUseUsageDescription",
)
DEPRECATED_KEY = "NSLocationAlwaysUsageDescription"
GENERIC_PLACEHOLDERS = {
    "description",
    "placeholder",
    "replace me",
    "tbd",
    "todo",
    "your description here",
}


class PrivacyCheckError(ValueError):
    """Raised when an Info.plist fails the location privacy check."""


def _meaningful_string(value, key):
    if not isinstance(value, str):
        raise PrivacyCheckError(f"{key} must be a string")
    normalized = " ".join(value.split()).casefold()
    if not normalized:
        raise PrivacyCheckError(f"{key} must be non-empty")
    if normalized in GENERIC_PLACEHOLDERS:
        raise PrivacyCheckError(f"{key} must not use a generic placeholder")
    return value


def load_plist(path):
    path = Path(path)
    if not path.is_file():
        raise PrivacyCheckError(f"plist not found: {path}")
    try:
        with path.open("rb") as source:
            plist = plistlib.load(source)
    except (OSError, plistlib.InvalidFileException, ValueError) as error:
        raise PrivacyCheckError(f"could not parse plist {path}: {error}") from error
    if not isinstance(plist, dict):
        raise PrivacyCheckError("plist root must be a dictionary")
    return plist


def validate_plist(path):
    plist = load_plist(path)
    for key in REQUIRED_KEYS:
        _meaningful_string(plist.get(key), key)
    if DEPRECATED_KEY in plist:
        raise PrivacyCheckError(f"deprecated key must be absent: {DEPRECATED_KEY}")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "plist",
        nargs="?",
        type=Path,
        default=SOURCE_PLIST,
        help="Info.plist to validate (defaults to the source Runner plist)",
    )
    args = parser.parse_args(argv)
    try:
        validate_plist(args.plist)
    except PrivacyCheckError as error:
        print(f"iOS location privacy check failed: {error}", file=sys.stderr)
        return 1
    print(f"iOS location privacy check passed: {args.plist}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
