# AI Repo Map

Use this for unfamiliar or multi-subsystem tasks. For known files or exact symbols, open them directly. For documentation-only tasks, skip testing and build notes.

## Task Routing

| Task | Read first | Then |
|------|-----------|------|
| Any Dart code or test change | `doc/AI_TESTING_NOTES.md` | Domain-specific file below |
| BLE transport, connection, GATT errors | `doc/AI_BLE_NOTES.md` | `lib/src/services/ble/`, `lib/src/controllers/connection/` |
| Bengle machine (MMR surface, capability mixins, wake sync) | `doc/AI_BENGLE_NOTES.md` | `lib/src/models/device/impl/bengle/`, `lib/src/models/device/impl/de1/unified_de1/*_capability.dart` |
| REST/WS endpoint changes | `doc/AI_API_NOTES.md`, read spec first | `lib/src/services/webserver/` |
| DE1 machine state, shot state | — | `lib/src/controllers/de1_state_manager.dart`, `de1_controller.dart`, `shot_sequencer.dart` |
| Profile/workflow serialization | `doc/Profiles.md` | `lib/src/models/data/`, `lib/src/daos/` |
| Database schema/migration | `doc/AI_STORAGE_NOTES.md` | `lib/src/database/app_database.dart`, `lib/src/daos/`, `lib/src/mappers/` |
| Plugin API or permissions | `doc/Plugins.md` | `lib/src/plugins/plugin_manager.dart`, `plugin_host.dart` |
| Skin serving or WebUI | `doc/Skins.md` | `lib/src/webui_support/`, `lib/src/services/webserver/webui/` |
| Device discovery or connection | `doc/DeviceManagement.md` | `lib/src/controllers/connection/connection_manager.dart` |
| Build, platform, CLI flags | `doc/AI_BUILD_NOTES.md` | `Makefile`, `pubspec.yaml` |
| Crashes, error tracing | `doc/AI_DEBUG_NOTES.md` | `lib/src/services/crashlytics_error_filter.dart` |
| Onboarding or settings UI | — | `lib/src/onboarding_feature/`, `lib/src/settings/`, `lib/src/launcher/` |
| Release process | `doc/RELEASE.md` | `.github/workflows/release.yml` |
| Historical design rationale | — | `doc/plans/archive/` — search for the feature name |

## Coupling

When you change X, also check Y and Z.

| Changing... | Must also check... | Why |
|-------------|---------------------|-----|
| BLE transport (`universal_ble_transport.dart`) | `UnifiedDe1Transport`, `De1Controller`, `ConnectionManager`, `CharSubscriptions`, crashlytics error filter, all transport tests | All layers share the `DataTransport` interface; gone-device handling affects error filtering |
| REST/WS endpoint (handler) | API spec (`rest_v1.yml` / `websocket_v1.yml`), router (`_init()`), `doc/Api.md`, handler test | Spec must stay in sync; stale spec = stale agent knowledge |
| Database schema (`app_database.dart`) | `@Database` version bump, migration in `onUpgrade`, DAOs, mappers, domain models (import prefixes) | Schema drift breaks persistence silently |
| Profile/workflow serialization | `Workflow.fromJson()`, `ProfileDao`, `ProfileStorageService`, legacy field backfill, spec | Dual representation (`context` + legacy fields); both must stay in sync |
| `ConnectionManager` | 7 collaborators (`DisconnectExpectations`, `StatusPublisher`, `ScanReportBuilder`, `DisconnectSupervisor`, `EarlyConnectWatcher`, `ScanOrchestrator`, `PolicyResolver`) | Delegate to the right collaborator rather than growing the manager |
| `De1StateManager` | `ShotSequencer`, `SteamSequencer`, `ScaleController` (sleep/wake), `ConnectionManager` (reconnect) | Machine state transitions cascade to shot lifecycle, scale power, and reconnect logic |
| Plugin API or permissions | `PluginManager`, `PluginHost`, [decentespresso/dye2](https://github.com/decentespresso/dye2), [decentespresso/shot-upload](https://github.com/decentespresso/shot-upload), [decentespresso/decaid-dcamp-plugin](https://github.com/decentespresso/decaid-dcamp-plugin), `doc/Plugins.md`, bundled plugin assets | Plugin host + bundled plugins must stay compatible |
| WebUI / skin serving | `lib/src/webui_support/`, `lib/src/services/webserver/webui/`, `doc/Skins.md` | Skin install, serving, and metadata are coupled |
| Device discovery | `DeviceMatcher`, `BleServiceIdentifier`, `ScanStateGuardian`, `ScanOrchestrator`, `doc/DeviceManagement.md` | Name matching, service verification, and scan lifecycle are interdependent |
| `BatteryController` / charging | `charging_logic.dart`, `De1Controller`, DE1 FW behavior (auto-re-enables charger) | Charger mode logic depends on DE1 FW quirks |

## Focused Tests

```sh
flutter test                                  # All tests
flutter test test/path/to/test.dart           # Specific file
flutter test --name "test pattern"            # Specific test
flutter analyze                               # Static analysis
dart format lib/ test/                        # Format
```

API smoke test: `scripts/sb-dev.sh start` then `curl` / `websocat` per `.agents/skills/decent-app/verification.md`.

## Avoid Reading Unless Needed

- `doc/plans/archive/` — historical design docs. Useful for why a decision was made, stale for current code.
- `test/` test files — read only the ones relevant to the change.
- `assets/` assets unrelated to API specs.
- `ios/`, `android/`, `macos/`, `linux/`, `windows/` — platform-native project files. Only touch when adding platform capabilities.
- `packages/dye2-plugin/` — DYE2 plugin source, **not built or bundled by Decaid**. The bundled copy is pinned and fetched from [decentespresso/dye2](https://github.com/decentespresso/dye2) releases via `scripts/fetch_dye2_plugin.sh` (see `doc/Plugins.md`). Do DYE2 compatibility work against that repo, not this in-tree copy.
- `assets/plugins/shot-upload.reaplugin/` — generated from the pinned [decentespresso/shot-upload](https://github.com/decentespresso/shot-upload) release by `scripts/fetch_shot_upload_plugin.sh`. Do shot-upload behavior work in that repository, not against the generated Decaid asset.
- `assets/plugins/dcamp.reaplugin/` — generated from the pinned [decentespresso/decaid-dcamp-plugin](https://github.com/decentespresso/decaid-dcamp-plugin) release by `scripts/fetch_dcamp_plugin.sh`. Do dcamp behavior work in that repository, not against the generated Decaid asset.
