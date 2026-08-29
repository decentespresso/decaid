# App Log Upload

## Goal

Add the Decaid client for the existing `POST /support/api/applog_upload`
endpoint so linked users can opt in to hourly support-log uploads.

## Design

- Keep upload logic native because plugins cannot read Decaid's log directory.
- Add an `AppLogUploadService` that reads current and rotated logs in
  chronological order, uploads only lines newer than a persisted watermark,
  and drains large backlogs in bounded chunks.
- Retry collection when rotated-file metadata changes so a rename cannot move
  unread content behind the collector.
- Recognize only Decaid's isolate-prefixed record headers. Other lines inherit
  the preceding record timestamp, so embedded timestamp or log-shaped text
  cannot poison the cursor.
- Reuse `DecentAccountService` for stored Basic credentials and authentication
  failure tracking.
- Use the currently connected real machine for serial and firmware identity.
- Default uploads off. Expose the toggle, upload-now action, and last result on
  the linked Decent Account page.
- Start the first background attempt after one minute and retry hourly. Drain a
  capped backlog after one minute without replacing a newer consent schedule.

## Security And Privacy

- Never expose account credentials outside `DecentAccountService`.
- Never upload without explicit opt-in, a linked account, and a real machine
  serial.
- Cancel preflight and cursor updates when consent changes during an upload, and
  ignore authentication failures from requests that predate a newer login.
- Clear stale cursors whenever the service starts disabled, covering interrupted
  opt-out persistence before a later opt-in.
- Persist opt-out before deleting linked-account credentials, and fail closed
  when an enabled service cannot find or read them.
- Persist consent in the encrypted account consent store.
- Bound connection establishment and abort timed-out HTTP requests before
  allowing a retry.
- Send only Decaid log text and the endpoint's required app and machine
  metadata.
- Keep request bodies below the server's existing upload limit.

## Verification

- Cover first-run 24-hour filtering, rotated-file ordering, watermark updates,
  chunking, disabled state, missing identity, authentication failures, and UI
  controls.
- Run formatting, focused tests, static analysis, and the full Flutter suite.
- Repeat severity audits and fix every P0/P1/P2 finding before opening a draft
  PR.
