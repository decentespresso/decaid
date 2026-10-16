# Shot Upload Tablet Verification

## Signing Preflight Result

The installed regular Decaid APK was preserved in ignored local runtime storage.
Its signing certificate differs from the configured project, test-lab, and
personal Android debug keys. No alternate signing configuration was found in
the project or current environment. The certificate mismatch prevents a
data-preserving in-place update with the available keys.

At this stage no APK was built or installed, and app data, login, plugins, and
shot history were not changed. Full native-host verification needs a
matching-signed APK or the isolated Decaid Test package. Plugin-only testing in
regular Decaid remains possible but cannot verify the native host changes.

## Approved Plugin-Only Check

The user subsequently approved updating only the uploader in regular Decaid.
The app reports 75 shots, one uploaded marker, and automatic upload disabled.
Keep automatic upload disabled so the remaining history is not uploaded.

Use the existing source-update API, which preserves settings, auto-load, and
plugin storage and rolls back a failed load. Save the original release package
and private before/after snapshots in ignored local runtime storage.

A temporary probe uses the real ownership guard and duplicate-upload path for
the already-uploaded shot. The probe rejects every upstream non-GET request and
local HTTP write. It does not modify machine settings or account identity.
After the check, replace it with the exact reviewed 0.2.4 source and manifest,
verify the probe endpoint is gone, and compare all shot metadata, settings,
recent upload records, and account status with the baseline.

## Observed Plugin-Only Results

On 2026-10-15, regular Decaid 0.8.8 accepted the local uploader update from
0.2.2 to unreleased 0.2.4. The original app build and signing identity were not
changed. The final source-update payload exactly matches the reviewed source
checkout and manifest; the temporary probe endpoint then returned HTTP 404.

The real authenticated machine-list GET returned HTTP 200, and the ownership
guard confirmed that the uploaded shot's capture-time serial is linked. The
same shot was excluded from reconciliation and skipped as already uploaded by
the actual upload function. The probe recorded one upstream GET, zero upstream
POSTs, and zero local HTTP writes. App logs confirmed no additional shot-upload
POSTs and no new unhandled promise rejections.

Structured before/after comparisons passed for all 75 shot metadata records,
the uploaded shot's complete record, plugin settings, recent upload history,
account status, and other plugins' versions/load preferences. The account stayed
logged in, one recent upload remained, and automatic uploads stayed disabled.
The new pause-status fields are available and report no active pause. Only the
ADB forward created for this check was removed; the regular app was left open.

The initial read-only probe used the wrong global fetch entry point and failed
before any upstream request. Capturing the plugin-scoped fetch corrected the
probe; production uploader source did not need changes. All probe guards and
the diagnostic endpoint were removed from the installed final candidate.

This live check does not verify real upstream 401/403 handling, ownership
changes, automatic backlog upload, or the new native notice/account-change
bridge. Those paths remain covered by the earlier automated/native-mock checks
or require a host build signed with the installed app's key.
The later isolated full-host Android check is recorded in `host-smoke.md`.

## Recovery

Never uninstall to bypass a signing or version failure. The original APK is a
local recovery artifact, not permission to roll back across a database migration.
If history or login changes unexpectedly, stop and report before further writes.
Account-private evidence stays under ignored local runtime storage.
