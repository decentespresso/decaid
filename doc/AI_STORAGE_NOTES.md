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

## Storage Ownership

| Store | Owner | Purpose |
|-------|-------|---------|
| Drift DB | `AppDatabase` | Shots, workflows, beans, grinders, profiles, settings |
| `SharedPreferences` | `SharedPreferencesSettingsService` | App settings (telemetry consent, feature flags, preferences) |
| Secure store | `DecentAccountService`, `PluginLoaderService` | Account credentials, API tokens, secure plugin settings |
| File system | `StorageService` | Data export, log files, skin assets |

Keep these stores independent. A settings reset must not clear account credentials unless explicitly requested.

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

## Keeping Notes Fresh

Add migration gotchas, storage ownership changes, and data integrity rules. Prune when schema versions are retired.
