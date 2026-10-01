# Scenario: backup import entry-count limit

Finite API check that an archive exceeding the ZIP entry limit is rejected with
its structured reason, while other invalid ZIPs retain the generic response.

## Preconditions

- `python3`, `curl`, and `jq` are installed.
- The app is running with the API available at `http://localhost:8080`.
- Import has no persistent side effects for rejected archives.

```bash
BASE=http://localhost:8080
TMP=$(mktemp -d)
python3 - "$TMP/too-many-entries.zip" <<'PY'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1], "w", compression=zipfile.ZIP_STORED) as archive:
    for index in range(4097):
        archive.writestr(f"entry-{index}.txt", b"")
PY
```

## Reject 4097 entries

```bash
code=$(curl -sS --max-time 30 -o "$TMP/too-many-entries.json" \
  -w '%{http_code}' -X POST "$BASE/api/v1/data/import" \
  -H 'content-type: application/zip' \
  --data-binary "@$TMP/too-many-entries.zip")
test "$code" = 400
jq -e '.error == "Invalid backup archive" and .reason == "too_many_entries"' \
  "$TMP/too-many-entries.json"
```

## Other invalid ZIP keeps the generic response

```bash
printf 'not a ZIP archive' > "$TMP/invalid.zip"
code=$(curl -sS --max-time 30 -o "$TMP/invalid.json" \
  -w '%{http_code}' -X POST "$BASE/api/v1/data/import" \
  -H 'content-type: application/zip' --data-binary "@$TMP/invalid.zip")
test "$code" = 400
jq -e '.error == "Invalid backup archive" and (has("reason") | not)' \
  "$TMP/invalid.json"
```

## Postconditions

```bash
rm -rf "$TMP"
```

The import endpoint rejected both archives with `400`; only the 4097-entry
archive returned `reason: "too_many_entries"`. No backup data was imported.
