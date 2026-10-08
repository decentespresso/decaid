# Plugin and Skin Action Menus

## Design

The Plugins page previously separated page actions into three unlabeled icons.
The Web Interface page separated installation from its update action. Both pages
now use a single cogwheel menu with icons and explicit action names.

Both cogwheels use 28-pixel icons and the primary button color from the theme.
Standard icon-button touch targets and disabled styling remain unchanged.

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
overflow the narrow-screen menu regression check.

## Scope

Updated Plugins and Skins documentation. No backend, API, plugin permissions,
skin selection, storage, or machine-control changes. The PR is based on current
main and excludes unrelated edits from the original workspace.

## Verification

- Focused widget tests: 43 passed, including cogwheel size and color assertions
  and both 320-pixel-wide menu checks.
- Flutter-rendered screenshot checks: 2 passed; captures use sample plugin and
  skin data in the original workspace, not the tablet.
- Full Flutter suite on the PR branch: 4777 passed, 2 skipped.
- Static analysis on the PR branch: no issues found.
- Changed Dart files pass the formatter check. Existing formatting differences
  elsewhere are left untouched.
- Verification used Flutter 3.44.8 on Windows with local SDK-pinned dependency
  resolution. SDK-only lockfile changes and ignored test assets are excluded
  from the PR. Bundled-skin test assets follow the existing CI stub convention.
- No tablet deployment. The regular Decaid app was left running and untouched.
