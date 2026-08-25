# Shot Upload Plugin Extraction

**Status:** Implemented 2026-08-25

## Goal

Move `shot-upload.reaplugin` from Decaid into a public standalone repository while preserving its current behavior and making it distributable and updateable through the same GitHub release mechanism as DYE2.

- Local checkout: `~/development/work/shot-upload.reaplugin`
- GitHub repository: `decentespresso/shot-upload`
- Initial standalone release: `v0.2.1`

## Agreed decisions

- Create `decentespresso/shot-upload` as a public repository.
- Start from a clean snapshot of the current plugin rather than preserving Decaid git history, matching the DYE2 extraction.
- Keep the plugin headless. It needs JavaScript for Decaid's `createPlugin(host)` contract but needs no HTML.
- Use plain JavaScript, JSON, shell, and GitHub Actions. Do not add Vite, TypeScript, npm dependencies, or a browser framework.
- Keep versions committed in source. A release tag must match both `manifest.json` and the version returned by `plugin.js`; CI validates rather than rewrites them.
- Do not change shot-upload behavior during extraction.

## Standalone repository

```text
shot-upload/
├── .github/workflows/release.yml
├── shot-upload.reaplugin/
│   ├── manifest.json
│   └── plugin.js
├── test/
│   └── plugin.test.js
└── README.md
```

### Source and tests

1. Copy the current Decaid `assets/plugins/shot-upload.reaplugin/` contents unchanged.
2. Add a dependency-free test harness using `node:test` and standard Node APIs.
3. Cover the behavior that automatic updates must not regress:
   - automatic upload remains opt-in;
   - `shotStored` uploads the persisted shot with captured machine identity;
   - reconciliation selects only eligible unmarked shots;
   - simulated and unavailable machine identities remain excluded;
   - reconciliation pauses while the machine is active;
   - consent denial or timeout pauses reconciliation;
   - transient failures retry later;
   - permanent rejection and successful upload markers prevent repeated posts;
   - manual upload retains its documented fallback behavior.
4. Document installation, development, testing, versioning, and release steps in `README.md`.

### Validation and release workflow

For pull requests and `main`:

- run `node --check shot-upload.reaplugin/plugin.js`;
- run `node --test test/plugin.test.js`;
- validate the manifest ID, API version, permissions, and required files;
- verify `plugin.js` exposes `createPlugin`;
- verify the manifest and plugin versions agree.

For `vX.Y.Z` tags:

- require the tag version to equal the committed plugin version;
- package the top-level `shot-upload.reaplugin/` directory as `shot-upload.reaplugin-vX.Y.Z.zip`;
- publish exactly one ZIP asset in the GitHub release;
- generate release notes.

The first release is `v0.2.1`, matching Decaid's current bundled copy so extraction causes neither an upgrade nor a downgrade.

## Decaid integration

### Fetch and bundle

1. Add `scripts/fetch_shot_upload_plugin.sh`, following `scripts/fetch_dye2_plugin.sh`:
   - pin release `v0.2.1` and its SHA-256;
   - allow repository/version/checksum/API-version overrides for local testing;
   - download the single `shot-upload.reaplugin-*.zip` release asset;
   - verify its checksum;
   - unpack it into `assets/plugins/shot-upload.reaplugin/`;
   - validate required files, manifest ID/version/API version, required permissions, and `createPlugin`.
2. Add `assets/plugins/shot-upload.reaplugin/` to `.gitignore`.
3. Delete the tracked Decaid copies of `manifest.json` and `plugin.js`.
4. Keep the existing `pubspec.yaml` asset path and `PluginLoaderService` bundled path unchanged.
5. Update every build/test workflow that fetches DYE2 to fetch shot-upload alongside it before Flutter touches bundled assets.

### Automatic updates

Add the canonical source mapping in `lib/src/plugins/plugin_source_service.dart`:

```dart
'shot-upload.reaplugin': 'decentespresso/shot-upload',
```

This seeds existing bundled installations with GitHub-release provenance. Future releases then use Decaid's existing update checks, transactional replacement, downgrade prevention, and permission-escalation approval.

Extend `test/plugins/plugin_source_service_test.dart` to verify that a bundled shot-upload installation is seeded with:

- repository `decentespresso/shot-upload`;
- source kind `githubRelease`;
- release tag matching the installed manifest version;
- no pinned asset name.

### Existing integration coverage

Keep the Decaid tests in place during extraction:

- `test/plugins/shot_upload_plugin_test.dart`
- `test/plugins/shot_upload_reconciliation_test.dart`
- `test/plugins/bundled_plugin_permissions_test.dart`

They will run against the fetched standalone release and continue to verify the real QuickJS host, account proxy, permissions, and Decaid REST interactions. Test removal or consolidation is a separate change if duplication later becomes costly.

### Documentation

Update:

- `doc/Plugins.md` to identify `decentespresso/shot-upload` as the source of truth and describe its pinned bundled release;
- `doc/AI_REPO_MAP.md` to route shot-upload compatibility work to the standalone repository.

No REST or WebSocket contract changes are planned, so the API specifications do not need modification.

## Implementation order

1. Create the local standalone repository and copy the current plugin.
2. Add standalone tests, documentation, and GitHub Actions validation/release packaging.
3. Create the public GitHub repository and push the initial source.
4. Tag and publish `v0.2.1`.
5. Verify the release archive contents and record its SHA-256.
6. Implement the Decaid fetch, ignore, workflow, provenance, test, and documentation changes on a feature branch.
7. Fetch the release and confirm it matches the pre-extraction plugin.
8. Run focused and full verification.
9. Archive this design plan under `doc/plans/archive/shot-upload-plugin-extraction/` before the Decaid PR is considered complete.

The standalone release must exist before Decaid stops tracking its bundled source, otherwise fresh checkouts and CI cannot populate the required asset directory.

## Verification

### Standalone repository

```bash
node --check shot-upload.reaplugin/plugin.js
node --test test/plugin.test.js
```

Inspect the release archive and ensure it has one plugin root containing only the expected distributable files.

### Decaid

```bash
./scripts/fetch_shot_upload_plugin.sh
dart format lib test
flutter test test/plugins/shot_upload_plugin_test.dart
flutter test test/plugins/shot_upload_reconciliation_test.dart
flutter test test/plugins/bundled_plugin_permissions_test.dart
flutter test test/plugins/plugin_source_service_test.dart
flutter analyze
flutter test
```

Smoke-test with `scripts/sb-dev.sh`:

- confirm the bundled plugin is present and loadable;
- confirm source metadata is seeded to `decentespresso/shot-upload`;
- exercise the status endpoint;
- exercise a manual upload far enough to verify Decaid dispatches to the fetched plugin, without requiring a successful production account upload.

## Acceptance criteria

- `decentespresso/shot-upload` is the authoritative source and has a valid `v0.2.1` release.
- A fresh Decaid checkout obtains shot-upload only through the pinned, checksum-verified fetch script.
- Decaid builds still bundle `shot-upload.reaplugin` on every platform.
- Existing plugin behavior and permissions are unchanged.
- Existing installations are associated with the canonical repository and can receive future releases through Decaid's updater.
- Standalone and Decaid test suites pass.

## Out of scope

- Adding an HTML settings or status UI.
- Refactoring the upload or reconciliation algorithm.
- Changing permissions, defaults, endpoints, or account-proxy behavior.
- Migrating other bundled plugins.
- Preserving the original per-file git history.

## Implementation result

- Standalone repository: <https://github.com/decentespresso/shot-upload>
- Initial release: <https://github.com/decentespresso/shot-upload/releases/tag/v0.2.1>
- Release SHA-256: `f404eca097c162c0ca17f828badeff1d5c8c831c49d2e38faa72ad2e7b1a1fdd`
- The release plugin files match the former Decaid assets byte for byte.
- Standalone tests, Decaid focused tests, `flutter analyze`, full `flutter test`, and the `sb-dev` load/status/reload smoke test passed.
