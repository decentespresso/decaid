# AI Storage Notes

Read this when changing database schema, migrations, persistent settings, SharedPreferences keys, or profile storage. Skip it for changes that only use runtime state.

## Source Of Truth

- Database: `lib/src/database/app_database.dart` (Drift/SQLite via `@Database` annotation).
- DAOs: `lib/src/daos/` (data access objects).
- Mappers: `lib/src/mappers/` (domain ↔ Drift row mapping).
- Profile storage: `lib/src/services/profile_storage_service.dart` → `DriftProfileStorageService` → `ProfileDao` → `ProfileRecords` table.
- Settings: `lib/src/services/settings_service.dart` → `SharedPreferencesSettingsService`.
- Storage service: `lib/src/services/storage_service.dart`.

## Hard Rules

- Schema version is tracked in the Drift `@Database` annotation. Bump it on every migration.
- New tables need a migration entry in the `onUpgrade` callback.
- Domain models and Drift-generated code share class names (`ShotRecord`, `Workflow`, `ProfileRecord`). Use prefixed imports: `import '...shot_record.dart' as domain;` or `hide Workflow` on the database import.
- Profiles go through `ProfileStorageService` interface, not direct DAO access.

## Storage Locations (issue #508)

Internal, non-user-authored data lives under Application Support on desktop (Linux/macOS/Windows). Mobile (Android/iOS) keeps the existing Documents-based layout; the app sandbox already isolates it there.

| Data | Desktop | Mobile |
|------|---------|--------|
| Drift database | `<support>/streamline_bridge.sqlite` | `<docs>/streamline_bridge.sqlite` |
| Hive boxes | `<support>/store` | `<docs>/store` |
| Installed plugins | `<support>/plugins` | `<docs>/plugins` |
| Web UI skins | `<support>/web-ui` | `<docs>/web-ui` |
| Logs (`log.txt`, `webview_console.log`) | `<support>/logs` | `<docs>` |

`AppDirectories` (`lib/src/services/storage/app_directories.dart`) is the single resolver. Consumers must not call `getApplicationDocumentsDirectory()` for internal state. There is no in-app migration: pre-change desktop users export a full backup before upgrading and restore after (rationale: `doc/plans/archive/app-data-out-of-documents/design.md`).

Gotchas:

- `RotatingFileAppender` requires its parent directory to exist at construction; `main()` creates the logs directory explicitly.
- `Hive.init()` does not register the Flutter `ColorAdapter`/`TimeOfDayAdapter` that `Hive.initFlutter()` did; `main()` calls `ensureFlutterTypeAdaptersRegistered()` after `Hive.init()`.
- Web UI downloads/extraction use `Directory.createTemp()` under the temp directory, never fixed names (`/tmp` is shared on Linux).
- Log readers (feedback, export, import report, discovery views) read `<logs>/log.txt` via `AppDirectories.logs`.
- CI (`pr-checks.yml` Linux build smoke) runs the app with controlled `XDG_DATA_HOME`/`XDG_CONFIG_HOME`, asserts resolved paths, then fresh-starts the app and requires `log.txt` under `XDG_DATA_HOME`.

## Storage Ownership

| Store | Owner | Purpose |
|-------|-------|---------|
| Drift DB | `AppDatabase` | Shots, workflows, beans, grinders, profiles, settings |
| `SharedPreferences` | `SharedPreferencesSettingsService` | App settings (telemetry consent, feature flags, preferences) |
| Secure store | `DecentAccountService`, `PluginLoaderService` | Account credentials, API tokens, secure plugin settings |
| File system | `StorageService` | Data export, log files, skin assets |

Keep these stores independent. A settings reset must not clear account credentials unless explicitly requested.

## Account Auth State (gh#696)

`DecentAccountService` stores `email` + encrypted password (`cryptpw`, returned by `login_test`) in the secure store. Stored credentials mean **linked**, not **authenticated**: `hasLinkedAccount()` is the presence check; `isLoggedIn()` is auth-aware and returns a cached in-memory state, validated against `/support/api/login_test` (memoized while in flight; only definitive results are sticky — an indeterminate network/5xx outcome sets a 30s cooldown (`retryInterval`) so widget rebuilds and status polls cannot hammer `login_test`, and the next check after the cooldown retries). `login_test` accepts `pw` or `cryptpw` and returns `0` (body `"0\n"`, status 200 — always trim before comparing) on rejection, otherwise the cryptpw. A definitive rejection (401 or `"0"`) marks the account not authenticated; 5xx/network errors are indeterminate and leave the cached state untouched. `DecentProxyService` reports upstream 401s via `onAuthFailure` -> `reportAuthenticationFailure()`. Credentials are kept on 401 — a transient backend failure must not destroy the link; the next session re-validates. Auth state carries a generation counter: login success, logout, and reported auth failures bump it, and an in-flight validation only writes its result if its generation is still current, so a stale validation of old credentials cannot clobber a newer successful login (or resurrect auth after a 401). Failed `login()` attempts never touch stored credentials (a bad replacement login cannot erase a working link).

Plugin settings marked `secure` in the manifest are stored through
`CredentialStore` under a plugin-scoped key. Ordinary plugin settings remain in
SharedPreferences. Reads exposed to UI and REST clients return only `{isSet}`
state for secure fields; `PluginLoaderService` joins the two stores only for
`onLoad`. Legacy cleartext values migrate on first read. `--no-account` uses
process-memory secure plugin values because headless Linux cannot access
libsecret.

## Database Schema

Persistence uses Drift (SQLite) via `AppDatabase`. DAOs in `lib/src/daos/`, mappers in `lib/src/mappers/`.

**Key tables:** `shots`, `steams`, `workflows`, `profiles`, `beans`, `bean_batches`, `grinders`, `settings`.

**Schema migration:** The `@Database` annotation's `version` field is the schema version. Migrations run in `onUpgrade` callback. Each version bump needs a corresponding migration step.

**Schema v5 (shot revision metadata):** `shot_records.createdAt`/`updatedAt` were added as nullable TEXT and backfilled from `timestamp` during the 4→5 migration, so pre-v5 rows carry a real DB-level revision instead of NULL. `ShotMapper.fromRow` still falls back to `timestamp` for any row with NULL fields (e.g. rows inserted without stamps). The revision contract (bookkeeping extras do not advance `updatedAt`, PUT cannot write the fields) is documented in `doc/Api.md` under Shots → Modification tracking.

## Profile Storage

Content-based hash IDs for deduplication. `ProfileController` manages the profile library:
- Hash computed from profile content (`Profile.fromJson` → `computeHash`).
- Deduplication: two profiles with identical content get the same hash ID.
- `ProfileStorageService` interface with `DriftProfileStorageService` implementation.
- ID-changing updates use `ProfileStorageService.replace`, which inserts the replacement and deletes the original in one Drift transaction. Target-ID collisions throw `ArgumentError` and leave both records unchanged.

### Legacy Profile Corpus Ingestion

`tools/ingest_profiles.py` rejects de1app TCL profiles whose type is `settings_2a`
or `settings_2b`, whether `advanced_shot` is empty or populated. de1app's stored
`advanced_shot` is not authoritative for these simple-profile types. Reaprime does
not maintain a duplicate implementation of de1app's frame generators; maintainers
must generate final advanced-profile JSON externally before adding such a profile.

## SharedPreferences Keys

Settings persist via `SharedPreferencesSettingsService`. Key prefixes are flat strings. Feature flags use the `FeatureFlag` enum + `SettingsService.featureFlag/setFeatureFlag` + `SettingsController.isFeatureFlagEnabled/setFeatureFlag`.

**First feature flag foundation (PR #371):** "Smart Step Advance" — the pattern for all future feature flags. Flag enum, settings service get/set, controller wrapper, UI toggle in Advanced Settings.

App log sharing consent is stored by `AccountConsentStore` under
`appLogUpload`. The `appLogUpload.` SharedPreferences prefix contains only
presentation state and the cursor. The cursor stores the last uploaded log
timestamp plus its line ordinal as one JSON value. Keep the timestamp and
ordinal atomic so capped uploads cannot skip later lines with the same timestamp.
Opting out clears the cursor, so a later opt-in starts with only the previous 24
hours instead of uploading the opt-out gap. Disabled startup also removes a
stale cursor left by an interrupted opt-out.

## Workflow Dual Representation

`Workflow.fromJson()` backfills `WorkflowContext` from legacy fields (`grinderData`, `coffeeData`, `doseData`). UI reads from `context`; API clients can write to either. Always keep both in sync when modifying serialization.

## Migration Checklist

- [ ] Bump schema version in `@Database` annotation.
- [ ] Add migration step in `onUpgrade` callback.
- [ ] Test migration from previous schema version.
- [ ] Test fresh install (no migration needed).
- [ ] Verify DAO and mapper support for new fields/tables.
- [ ] Update domain models if schema changes affect the public API.

## Focused Tests

```sh
flutter test test/daos/
flutter test test/database/
flutter test test/services/storage_service_test.dart
```

## Export Paging (issue #555)

Backup export pages collections instead of calling `getAll...()`. Shots and
steams page via keyset cursors ordered by `(timestamp, id)` ascending
(`getShotsForExport` / `getSteamsForExport`); beans and grinders page by
`(createdAt, id)` (`getBeansForExport` / `getGrindersForExport`). Cursor
paging is stable under concurrent inserts/deletes — no duplicates or
omissions — which offset paging cannot guarantee. The page functions are
built in `main.dart` from the DAOs and carried by `BackupDataSources`; the
storage service interfaces are unchanged.

## Plugin Settings Schema Reconciliation (issue #655 follow-up)

Persisted plugin settings are values of the **current manifest schema**, not
an independent schema-less document. Every read path (Flutter settings UI,
REST GET, plugin load/reload, future frontends) routes through
`PluginLoaderService._storedSettings()`, which reconciles persisted ordinary
and secure settings against the current `PluginManifest`:

- Key no longer declared by the manifest -> dropped (a manifest with
  `settings: {}` therefore drops every previously persisted value).
- Enum value no longer in `values` -> reset to the manifest `default` when
  that default is itself a declared value, otherwise dropped.
- Value incompatible with the declared type (`string`/`number`/`boolean`) ->
  reset to the manifest `default` when the default matches the type,
  otherwise dropped.
- Cleaned state is written back to storage (`plugin.settings.<id>` and the
  secure store) so stale values do not return.
- Settings whose schema has no usable `type` are left untouched (cannot be
  judged).
- **Secure values are not opaque**: the same enum/type reconciliation applies
  to values in secure storage. Reconciliation always happens in secure
  storage only — a value that no longer fits the schema is reset or dropped
  and is never written to ordinary storage.
- Keys that are `secure: true` in the current manifest are migrated out of
  ordinary storage by the legacy migration path. A value whose secure flag
  was removed is never copied back into plaintext and simply reverts to
  unset.

**`_validateSettings()` is unchanged**: caller-supplied keys are still
validated strictly against the current manifest, including the existing
empty-schema early return (a caller may still write to a plugin whose
manifest declares no settings, but the next read reconciles those values
away). Reconciliation only ever touches host-owned persisted state, never
caller payloads.

**Failed installs/updates are transactional**: `installPluginPackage()` and
`updatePluginSource()` snapshot raw persisted settings (ordinary + secure)
before mutating, and `_restorePersistedSettings()` restores them verbatim on
rollback, before the previous version is reloaded. A failed update leaves
both the previous plugin version and its settings exactly as they were
before the attempt.

Renames are not inferred: `OldName -> NewName` behaves as removed + added.

## Keeping Notes Fresh

Add migration gotchas, storage ownership changes, and data integrity rules. Prune when schema versions are retired.
