# Plugin and Skin Action Menus

## Design

The Plugins page previously separated page actions into three unlabeled icons.
The Web Interface page separated installation from its update action. Both pages
now use a single cogwheel menu with icons and explicit action names.

Both cogwheels use 28-pixel icons and the primary button color from the theme.
Standard icon-button touch targets and disabled styling remain unchanged.
Outside taps dismiss either menu without activating the underlying control.
During plugin and skin update checks, the cogwheel shows a fixed-size, 28-pixel
progress indicator in the same primary color, so progress remains visible after
the menu closes. The update item is disabled while busy, and repeat invocations are ignored
before the asynchronous check starts. Both success and failure restore the
cogwheel and enable another check. Completion after leaving either page is safe.

Both pages use `PageActionMenu`, which owns the common shell, busy state, update
item, and installation source submenu. Pages retain their update operations and
result messages; Plugins supplies its extra refresh action and folder source.
The skin progress snackbar is replaced by the same persistent indicator used
for Plugins, so completion and error messages are not queued behind it.

The Plugins menu retains Refresh plugins, Check for updates, and Install plugin.
The skin menu retains Check for updates and Install skin. Installation expands
the existing source choices without classifying any source as advanced. The
plugin folder source remains available alongside GitHub releases, branches, and
ZIP files; skins keep their three existing sources.

Plugin cards retain their three-dot menu, status, permissions, source details,
pending update approval, and startup switch. The duplicated Load/Unload and
Settings buttons are removed. Loading, installation restrictions, initialization
errors, and permission approval keep their existing behavior.

The skin dropdown fills its available width and constrains labels so it does not
overflow the narrow-screen menu regression check. Skin action button labels can
wrap within their available width, including Linux's longer Open in Browser
label.

## Scope

Updated Plugins and Skins documentation. No backend, API, plugin permissions,
skin selection, storage, or machine-control changes. The PR is based on current
main and excludes unrelated edits from the original workspace.

## Shared Menu Verification (2026-10-09)

- Regression tests reject duplicate update invocations before a rebuild on both
  pages, assert persistent skin progress and disabled update actions, and cover
  skin failure/retry and update completion after leaving either page.
- Full `flutter test --no-pub --concurrency=4`: 4785 passed, 2 skipped, including
  all 51 affected widget tests.
- `flutter analyze --no-pub`: no issues found.
- `dart format lib test`: 919 files, 0 changed on the final formatter run.
- Windows verification used Flutter 3.47.6 / Dart 3.13.5. No tablet redeployment
  was performed for the shared-menu extraction.

## Earlier Verification

- Focused widget tests: 47 passed, including cogwheel size and color assertions,
  consumed dismissal taps, persistent update progress, both 320-pixel-wide menu
  checks, and a long, versioned, removable skin name.
- Flutter-rendered screenshot checks: 2 passed; captures use sample plugin and
  skin data in the original workspace, not the tablet.
- Full Flutter suite on the PR branch with CI's four-worker setting: 4781 passed,
  2 skipped.
- A default-concurrency Windows run left six native-JS authority tests
  incomplete. Their suite passed alone, and the four-worker full run passed.
- Static analysis on the PR branch: no issues found.
- Changed Dart files pass the formatter check. Existing formatting differences
  elsewhere are left untouched.
- Verification used Flutter 3.47.6 / Dart 3.13.5 on Windows, matching CI. No
  tracked lockfile changes. Bundled-skin test assets follow the existing CI stub
  convention.
- Tablet interaction verification passed on 2026-10-08 at `fdfd0d0e`, using the
  isolated test package. Captures and interaction details are recorded in the
  PR. The regular package and its data were not replaced or cleared.
