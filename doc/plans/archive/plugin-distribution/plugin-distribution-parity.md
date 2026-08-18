# Plugin distribution parity with WebUI skins (issue 626)

## Goal

Plugins gain the same managed distribution model WebUI skins already have:
install from a GitHub release, a GitHub branch, a local ZIP or a local folder,
with provenance recorded for the GitHub-backed sources and automatic update
checks on the existing update cadence. Permission escalation never installs
unattended.

## Layering

```
PluginManager            execution + permissions (unchanged)
PluginLoaderService      storage, lifecycle, locks, staged swap, rollback
PluginSourceService      provenance, GitHub fetch, update checks, approvals   <- new
PluginsHandler / UI      transport
```

`PluginSourceService` owns nothing about execution. It stages a candidate on
disk, validates it, decides whether the update may proceed, and hands the
staged directory to `PluginLoaderService`, which performs the mutation under
the existing per-plugin lock.

## Package validation (`plugin_package.dart`)

One validation path for every source. A staged directory is resolved to a
single plugin root, then checked:

- exactly one plugin root: either the staged directory itself contains
  `manifest.json`, or exactly one immediate subdirectory does (GitHub archives
  and release ZIPs wrap their content in one directory). More than one
  candidate root is ambiguous and rejected rather than guessed.
- `manifest.json` and `plugin.js` both present.
- the manifest parses through `PluginManifest`.
- the manifest id passes `isSafePathComponent`.

Validation happens before any mutation of the installed plugin.

## Transactional package install

`PluginLoaderService.installPluginPackage(stagedDir)` replaces the guts of
`addPlugin`:

1. take the per-plugin mutation lock;
2. reject downgrades through the existing `comparePluginVersions` policy;
3. record loaded state, unload if loaded;
4. rename the installed directory aside, copy the staged tree into place;
5. reload if it was loaded;
6. on any failure restore the renamed directory, the manifest cache and the
   running plugin, then rethrow.

`addPlugin` keeps its signature and delegates, so the folder-snapshot path in
`PluginsSettingsView` and existing callers are unchanged. Settings and the
auto-load preference live in `SharedPreferences` and are untouched by a package
swap.

## Provenance storage

Source metadata is a Decaid-owned `.rea_source.json` inside the plugin
directory - the same shape of decision as WebUI's `.rea_metadata.json`.
Consequences that make this the cheap choice:

- `removePlugin` deletes the directory, so removal clears the metadata with no
  extra wiring or removal callbacks;
- a package install writes the file after the swap, so it always describes the
  content actually installed;
- `updatePluginSource` (the REST source PUT) is a partial write of
  `manifest.json` + `plugin.js`, so it leaves provenance alone.

Recorded fields: source kind, `owner/repo`, branch, resolved commit, release
tag, asset name, prerelease flag, `installedAt`, `lastChecked`, and a pending
update block when an update is held back for permission approval.

Local ZIP and folder installs write no metadata: they are untracked snapshots
and never auto-update.

## GitHub sources

- **Release.** `GET /repos/{repo}/releases/latest`, or `/releases` when
  prereleases are allowed. The tag must be `X.Y.Z` or `vX.Y.Z` and must equal
  the manifest version after stripping the optional `v`. Assets: an explicit
  asset name selects; otherwise exactly one `.zip` asset must exist - several
  ZIP assets are an error asking for an explicit selection, not a guess.
- **Branch.** `GET /repos/{repo}/commits/{branch}` resolves the head SHA, then
  the branch archive is downloaded. The SHA is the update signal, so a branch
  install updates even when `manifest.version` never changes.

ZIP extraction reuses `extractArchiveToDirectory` from
`webui_support/webui_zip_support.dart` (a pure, hardened helper - reusing it is
not a coupling to WebUI storage). Extraction always targets a temporary
staging directory, never the installed plugin directory.

## Permission escalation

The candidate's permission set is compared with the installed manifest's:

- same or a strict subset: an automatic update may proceed;
- anything added: the update is not installed. The pending block records the
  candidate version/revision and the added permissions, and the plugin is
  reported as approval-required until the user approves it, at which point the
  same install path runs with the escalation accepted.

A user-initiated install (UI or REST) is itself the approval, so the gate
applies to automatic updates and to approving a recorded pending update.

## Update checking

`PluginSourceService.updateAllPlugins()` mirrors `WebUIStorage.updateAllSkins()`
and is called from `UpdateCheckService` beside the skin update, on the existing
timer. Per plugin: compare the tracked release tag or commit; unchanged means
only `lastChecked` moves; changed means download, validate, apply the
permission gate, then install or record a pending update. One plugin's failure
is logged and never aborts the loop.

## REST API

Named to match the skin endpoints:

| Method | Path |
|--------|------|
| POST | `/api/v1/plugins/install/github-release` |
| POST | `/api/v1/plugins/install/github-branch` |
| POST | `/api/v1/plugins/update` |
| POST | `/api/v1/plugins/{id}/update/approve` |

`GET /api/v1/plugins` gains a `source` block and a `pendingUpdate` block. No
plugin settings values are exposed. The existing unimplemented
`POST /api/v1/plugins/install` URL stub stays a 501 that points at the explicit
endpoints; arbitrary remote ZIP URLs remain out of scope.

## Native UI

The install button becomes a menu: GitHub Release, GitHub Branch, ZIP file,
Folder snapshot. The plugin card gains a compact source/state line and a
`Check for updates` action. An approval-required plugin shows the added
permissions and installs only after explicit confirmation.

## Out of scope

Bundled plugins keep the app-owned startup copy path. Arbitrary remote ZIP URL
installation is not added.
