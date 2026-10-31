# fastlane

App Store Connect metadata for Decaid. Text lives in `metadata/<locale>/`,
screenshots in `screenshots/<locale>/`. fastlane infers the screenshot display
type from the image dimensions, so device names in filenames are not required.

Builds are uploaded to TestFlight by CI (`.github/workflows/release.yml`).
This setup pushes listing text and screenshots, and submits the version for
review on request, always with a manual release.

## Credentials

The API key `.p8` lives at `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`.
`deliver --api_key_path` expects a JSON key file, not the `.p8` itself, so build
one outside the repo:

    python3 - <<'PY'
    import json, pathlib
    key = pathlib.Path.home() / ".appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8"
    out = pathlib.Path("/tmp/asc_key.json")
    out.write_text(json.dumps({
        "key_id": "<KEY_ID>",
        "issuer_id": "<ISSUER_ID>",
        "key": key.read_text(),
        "in_house": False,
        "duration": 1200,
    }))
    out.chmod(0o600)
    PY

## Common commands

    # Pull the live listing first and diff it against this folder
    fastlane deliver download_metadata --api_key_path /tmp/asc_key.json --metadata_path /tmp/asc-live

    # Push text only
    fastlane deliver --api_key_path /tmp/asc_key.json --skip_binary_upload --skip_screenshots

    # Push text and screenshots
    fastlane deliver --api_key_path /tmp/asc_key.json --skip_binary_upload --overwrite_screenshots

    # Attach a processed build and submit for review (manual release)
    fastlane deliver --api_key_path /tmp/asc_key.json --skip_binary_upload \
      --submit_for_review true --automatic_release false --build_number <n>

## Screenshot sizes

App Store Connect requires the 6.9-inch iPhone set and, for iPad apps, the
13-inch iPad set. fastlane maps dimensions to display types:

- iPhone 6.9-inch: 1320x2868 or 2868x1320
- iPad 13-inch: 2064x2752 or 2752x2064

Both sets are in place: `screenshots/en-US/iphone69_*` and
`screenshots/en-US/ipad13_*`. 1206x2622 from an iPhone 17 Pro lands in the
6.1-inch set, which does not satisfy the required slot.

The launcher screenshots were captured against a simulated machine and show
"MockDe1". Re-capture them on real hardware before submitting for review.
