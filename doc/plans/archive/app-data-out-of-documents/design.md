# Move application-managed data out of Documents (no migration)

Issue: decentespresso/decaid#508 · Parent: #445 · 2026-08-20

## Decisions (grilled, agreed)

- Desktop-only (Linux/macOS/Windows). Android/iOS paths unchanged.
- Logs → Application Support, persistent.
- **No in-app migration.** Desktop users export a full backup before upgrading and restore after. Accepted coverage gap: manually installed plugins and app prefs are not in the backup zip; web-ui skins re-download and bundled plugins re-copy automatically.
- Communication: release note + changelog only. No in-app notice.
- Smoke-test mode: `--print-storage-paths` CLI flag.

## Skipped

- Legacy migration (copy/rename/validation) — dropped by decision; users do manual backup & restore.
- Extending backup zip to include plugins/prefs — accepted gap.
- In-app migration notice.
