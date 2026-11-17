# fastlane

App Store Connect metadata for Decaid. Text lives in `metadata/<locale>/`,
screenshots in `screenshots/<locale>/`. fastlane infers the screenshot display
type from the image dimensions, so device names in filenames are not required.

Builds are uploaded to TestFlight by CI (`.github/workflows/release.yml`).
This folder holds listing text and screenshots, which are captured by hand,
committed here, and pushed by a manual `deliver` run. CI never produces or
uploads listing assets. Submitting the version for review is a deliberate step,
always with a manual release.

## Credentials

The API key `.p8` lives at `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`.
`deliver --api_key_path` expects a JSON key file, not the `.p8` itself, so build
one outside the repo. `mkstemp` creates it with `0600` before anything is
written:

    python3 - <<'PY'
    import json, os, pathlib, tempfile
    key = pathlib.Path.home() / ".appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8"
    handle, path = tempfile.mkstemp(prefix="asc_key-", suffix=".json")
    with os.fdopen(handle, "w") as out:
        json.dump({
            "key_id": "<KEY_ID>",
            "issuer_id": "<ISSUER_ID>",
            "key": key.read_text(),
            "in_house": False,
            "duration": 1200,
        }, out)
    print(path)
    PY

Use the printed path as `$KEY_JSON` below, and delete the file when done.

## Common commands

    # Pull the live listing first and diff it against this folder
    fastlane deliver download_metadata --api_key_path "$KEY_JSON" --metadata_path /tmp/asc-live

    # Push text only
    fastlane deliver --api_key_path "$KEY_JSON" --skip_binary_upload --skip_screenshots

    # Push text and screenshots (Deliverfile leaves screenshot replacement off by default)
    fastlane deliver --api_key_path "$KEY_JSON" --skip_binary_upload --overwrite_screenshots

    # Attach a processed build and submit for review (manual release)
    fastlane deliver --api_key_path "$KEY_JSON" --skip_binary_upload \
      --submit_for_review true --automatic_release false --build_number <n>

## Crash logs

fastlane has no action for TestFlight crash feedback (`pilot` only lists builds
and testers), so `scripts/fetch_testflight_crash_logs.rb` reads it from the App
Store Connect API with the same key JSON:

    # Text only: what testers wrote, and when
    ruby scripts/fetch_testflight_crash_logs.rb --api-key-path "$KEY_JSON" --list-only

    # Write each crash log to /tmp/testflight-crash-logs/<submission id>/
    ruby scripts/fetch_testflight_crash_logs.rb --api-key-path "$KEY_JSON"

Crash logs carry tester device and build details, so they default to a path
outside the repo, in `0700` directories holding `0600` files. Do not commit them.

## Screenshot sizes

App Store Connect requires the 6.9-inch iPhone set and, for iPad apps, the
13-inch iPad set. fastlane maps dimensions to display types:

- iPhone 6.9-inch: 1320x2868 or 2868x1320
- iPad 13-inch: 2064x2752 or 2752x2064

fastlane's docs suggest keeping screenshots out of git because `snapshot` can
regenerate them. These are captured by hand, so they are versioned on purpose.

Both sets are in place: `screenshots/en-US/iphone69_*` and
`screenshots/en-US/ipad13_*`. 1206x2622 from an iPhone 17 Pro lands in the
6.1-inch set, which does not satisfy the required slot.

The launcher screenshots were captured against a simulated machine and show
"MockDe1". Re-capture them on real hardware before submitting for review.
