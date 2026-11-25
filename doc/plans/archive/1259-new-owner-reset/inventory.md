# New-owner reset: retention and store ownership

Design rationale for [#1259](https://github.com/decentespresso/decaid/issues/1259), inspected at
`2aad5d145fc16f48c70abc660bb6e8ff2df22242`. Only the inactive journal foundation is implemented;
this inventory is not evidence that a provisioned installation can be reset safely.
See [journal slice](journal-slice.md) for the implemented boundary and
[capabilities](capabilities.md) for native-store limitations.

## Retention boundary

Reset must use an allowlist, not a list of sensitive keys to remove:

- Preferred machine and scale IDs, preserving existing null/sentinel/transport semantics, plus only
  necessary reconnect metadata for those two devices. Never retain account ownership mappings,
  preferred grinder, auxiliary sessions or the whole remembered-device registry.
- Real selected/default managed skin ID and its validated runnable package, plus normal bundled
  defaults. No browser profile, personal state, installation backup or entire web-ui volume.
  Unsupported/unmanaged/external selection must be explicitly resolved before destructive work;
  never silently switch it. Restoration/serving failure must remain visible and retryable.
- OS permissions/settings and actual machine configuration/calibration remain untouched. No reset,
  calibration or provisioning writes to hardware are authorized by retaining an ID.

`SettingsService` stores preferred IDs/default skin; quick settings also stores
`selected_webui_skin_id`. A future preflight must resolve disagreement with the active managed skin,
not guess. `RememberedDevice` carries id/name/type/implementation/transportType. For a preferred
manual `wifi:<host>` scale, only the necessary selected host may be reconstructed, not the old host
list. `usb-hds:any` is a scale selector, not a machine identity.

The journal schema carries identifiers/package reference only. It is not the final reconnect or
package-validation implementation. Retained choices do not complete onboarding steps; future steps
must preselect real restored choices and still request fresh customer consent.

## Owners and required fresh-install verification

Every verification below remains required before a live reset can report success. Seed factory
canaries, reconstruct owners from disk, inspect raw scoped state and compare with a clean install
of the same build. Empty controller fields alone are not proof.

| Store / current owner | Reset and verification boundary |
|---|---|
| SQLite, `AppDatabase` / `DatabaseReset` | Close writers/handles first. Include database, WAL/SHM/journal sidecars and `.reset-*` quarantines. Seed every user table/upload metadata; verify no canaries and normal stock profile/workflow restoration. |
| Hive, `HiveStoreService`, plugin host.storage and API KV | Close all boxes, including unopened/orphan on-disk namespaces. Reconstruct and enumerate after reset; no factory queues or namespaces. Wrapper currently has no close method. |
| Legacy/Async SharedPreferences | Clear the owned scope, restore allowlist through owners, invalidate both caches. Include unknown keys, shot-upload pending JSON decision, legacy opt-in and persisted AutoUpload before pre-loader migration. |
| Notification snapshot / machine settings / camera consent / Wi-Fi hosts | Separate cached owners must observe fresh state. No stale notices/actions, app consent or unrelated remembered selections. OS permission grants are not app consent. |
| Account credentials and registered-machine/identity caches | Reuse `DecentAccountService.logout()` and account write lock/generation fencing; verify scoped keys absent and late login/refresh cannot recreate identity. No cloud deletion/revocation. |
| Account consent and pending prompts | Existing `AccountConsentStore` needs serialized reset/in-memory invalidation; fence pending gate callbacks. Remove both allowed and denied choices, not just flags. |
| Persisted API tokens / runtime proxy and extension registries | Revoke through controller/service and fence new registration. Removing on-disk records alone leaves runtime tokens active. |
| Secure app/plugin stores and GitHub PAT | Enumerate exact owned namespaces including orphan plugin keys/migrations; strict readback and isolation sentinels. No-account mode must still clean production stores or fail. See native limitations. |
| Plugin packages, updates, ordinary/secure settings, permissions and queues | Reuse awaited loader/manager teardown. Recreate bundled build assets with fresh permissions/upload defaults, not factory-updated packages. No pending factory choice replay. |
| Managed skins, metadata, package backups and staging | Keep only validated selected package plus fresh bundled defaults. Verify selected ID resolves/serves offline; no personal files or non-selected custom packages. |
| Embedded browser website data, credentials and sessions | Cookies/cache alone are insufficient. Include IndexedDB, local/session storage, service workers, HTTP authentication and client-cert/SSL decisions with scoped canaries/cold-process readback. |
| Logs and app-log upload state | Close/detach sinks and drain existing uploads without starting another. Remove literal logs/rotations, cursor/result/timestamps and actual consent after disabling sharing. Mobile logs path is the Documents root: never recursively clear it as a log-only directory. |
| Temp/download/import/export staging and internal backups | Exact owned paths/receipts only; preserve external exports and unrelated files. Interrupted unreceipted shared-temp artifacts cannot be attributed by prefix. |
| Analytics, Crashlytics and Performance queues/caches | Disable/fence collection and reset supported identity/data; unsupported required purge means failure, not success. No factory payload may become eligible when customer consent changes. |
| Onboarding presentation and replay | Reuse shared progress semantics without changing replay-only behavior, CLI force/bypass or existing consent validation. Replay remains non-destructive. |

## Lifecycle rationale

`main.dart` initializes logs/Firebase/DB/accounts/uploads before the native UI. Recovery admission
only in an onboarding widget would be too late. Future integration must use existing composition
and subsystem owners, gate all sensitive work, reject brewing/steaming/firmware/incompatible writes,
and drain callbacks before deleting any store. No parallel app lifecycle manager is needed.

A non-secret marker and retained package/configuration must precede deletion. Partial failure stays
in guarded recovery, never mixed-owner normal operation. Ready follows deletion, restoration and
readback; explicit handoff acknowledgement must precede a later cold-process onboarding launch.
The current journal models these transitions only. SDK/browser cleanup, native startup admission,
complete storage ownership and physical end-to-end verification remain unresolved.
