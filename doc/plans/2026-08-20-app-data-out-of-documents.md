# Move application-managed data out of Documents (no migration)

Issue: decentespresso/decaid#508 · Parent: #445 · 2026-08-20

## Decisions (grilled, agreed)

- Desktop-only (Linux/macOS/Windows). Android/iOS paths unchanged.
- Logs → Application Support, persistent.
- **No in-app migration.** Desktop users export a full backup before upgrading and restore after. Accepted coverage gap: manually installed plugins and app prefs are not in the backup zip; web-ui skins re-download and bundled plugins re-copy automatically.
- Communication: release note + changelog only. No in-app notice.
- Smoke-test mode: `--print-storage-paths` CLI flag.

## Changes

1. **`lib/src/services/storage/app_directories.dart`** — single `AppDirectories` service. Static async getters resolving: `support`, `cache`, `temp`, `logs`, `hive`, `drift`, `plugins`, `webUi`. Base dir per platform: `getApplicationSupportDirectory()` on desktop, `getApplicationDocumentsDirectory()` on mobile (no behavior change there). Temp always `getTemporaryDirectory()`.

2. **`lib/main.dart`**
   - Log appender: `$appDocsPath/log.txt` → `AppDirectories.logs/log.txt`
   - `webViewLogService` dir → `AppDirectories.logs`
   - `Hive.initFlutter('store')` → `Hive.init(<appSupport>/store)`
   - `--print-storage-paths`: resolve, print paths, exit 0

3. **`lib/src/services/database/database.dart`** — `driftDatabase(name:)` → add `databaseDirectory:` resolving to `AppDirectories.support` (drift_flutter already supports it).

4. **`lib/src/plugins/plugin_loader_service.dart`** — plugins dir → `AppDirectories.plugins`.

5. **`lib/src/webui_support/webui_storage.dart`** — web-ui dir → `AppDirectories.webUi`.

6. **Log readers** (5 spots read `docs/log.txt`): feedback_service, data_management_page, import_result_view, device_discovery_view, scan_flow_view → read `AppDirectories.logs/log.txt`.

7. **CI** (`release.yml` desktop job): run app with `--print-storage-paths`, assert no Documents/$HOME in output.

8. **Issue bookkeeping** — edit #508 body: strike migration acceptance criteria, mark them out of scope with rationale.

## Verification

- Unit tests: AppDirectories resolution on desktop vs mobile platforms; Hive/Drift/plugins/webUi/log path derivation.
- `dart format lib test`, `flutter analyze`, full `flutter test`.
- Smoke: `flutter run --dart-define=simulate=1 -- --print-storage-paths` on macOS shows Application Support paths.
- Fresh desktop install: `store/`, `streamline_bridge.sqlite*`, `plugins/`, `web-ui/`, `log.txt` all created under Application Support; Documents untouched.

## Skipped

- Legacy migration (copy/rename/validation) — dropped by decision; users do manual backup & restore.
- Extending backup zip to include plugins/prefs — accepted gap.
- In-app migration notice.
