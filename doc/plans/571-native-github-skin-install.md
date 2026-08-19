# #571 — Native GitHub Skin Install Plan

## Goal

From **Launcher → Skins**, let a user install a skin from either:

- the latest GitHub release for an `owner/repo`; or
- a named GitHub branch for an `owner/repo` (default `main`).

The installed skin appears in the existing skin selector and participates in the existing update/remove behavior.

## Existing foundation

`WebUIStorage` already provides and tests both operations:

- `installFromGitHubRelease(repo, assetName: ...)`
- `installFromGitHub(repo, branch: ...)`

Both install through the existing ZIP extraction and skin-ID validation, rescan installed skins, and persist source metadata so **Check for updates** can refresh the skin later. The REST API already exposes the same operations. This task only adds the missing native Flutter UI.

## Scope

1. **Add an install menu to `SkinSelectorPage`.**
   - Add a visible `+` / **Install skin** action, following the existing Plugins settings pattern.
   - Offer **GitHub Release**, **GitHub Branch**, and the existing **ZIP file** flow from one place.
   - Keep live-edit folder selection separate because it serves a development folder rather than installing a managed skin.

2. **Add the two small GitHub dialogs.**
   - Release: repository (`owner/repo`) and optional ZIP asset name.
   - Branch: repository (`owner/repo`) and branch, defaulting to `main`.
   - Trim fields; require a non-empty repository; let `WebUIStorage` report invalid repositories, missing releases/assets, and download failures.

3. **Run the existing installers and refresh the page.**
   - Call `installFromGitHubRelease` or `installFromGitHub` directly.
   - Show installation success/failure in a snackbar.
   - Rebuild the selector after completion so the installed skin is immediately available for selection.
   - Do not automatically activate the skin: these storage methods intentionally return no skin ID, and installation is distinct from choosing the active skin.

4. **Document the native install options.**
   - Update `doc/Skins.md` to describe GitHub Release, GitHub Branch, and ZIP installation from Launcher → Skins.

## Tests first

Extend the skin-selector widget coverage with a fake `WebUIStorage`:

- choosing **GitHub Release**, entering `owner/repo` plus an optional asset, and confirming calls `installFromGitHubRelease` with those values;
- choosing **GitHub Branch**, entering `owner/repo` plus a branch, and confirming calls `installFromGitHub` with those values;
- each successful install refreshes the selector and reports success; failures remain on the page and report the storage error.

Existing `webui_storage_install_test.dart` coverage remains authoritative for download, extraction, provenance, and later update behavior; no duplicate network/storage tests are needed.

## Verification

1. `dart format lib test`
2. Run the new skin-selector widget tests and `test/webui_storage_install_test.dart`.
3. `flutter analyze`
4. `flutter test`
5. In a simulated app, navigate Launcher → Skins and install one release and one non-default branch; confirm each appears in the selector and can be selected, updated, and removed.

## Explicitly out of scope

- skin marketplace/store browsing;
- arbitrary URL entry;
- GitHub authentication or private repositories;
- prerelease selection;
- changes to `WebUIStorage`, REST endpoints, or API specifications;
- automatically selecting or launching the newly installed skin.
