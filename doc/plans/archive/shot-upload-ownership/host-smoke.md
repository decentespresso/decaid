# Shot Upload Host Smoke

## Scope

Verify the reviewed native notice, browser-return refresh, and sign-in recovery
in a full Android Decaid Test build. Preserve regular Decaid and its data.

## Isolation

Stage HEAD plus the seven reviewed host files and new notice widget under the
ignored shared lab directory, without changing either source checkout. Retarget
only that staged build to the existing test package. Include the exact uploader
source in the staged assets without changing the repository's generated bundle.

Use a test-only constructor-injected credential store and HTTP client, with fake
credentials and controlled ownership/authentication responses. No real account
credentials are read or used. Expose test controls only through the debug VM
service over USB. Keep the production proxy, account service, event bridge,
notification widget, account page, login form, and platform browser callbacks.

Exclude real discovery services from the staged bootstrap. Synthetic shot reads
and annotation writes are handled in memory; upstream uploads never leave the
fake client. No physical function, persisted shot, firmware, or machine setting
may be changed. Leave the tablet read-only safety guard in place.

## Evidence

Check the package, signer, included source hashes, and uploader asset before
installing. Observe native notices and navigation, actual Android background and
resume around Support, and account recovery through the real login form. Record
mock request/event counters and screenshots in ignored local runtime storage.
Restore test-only plugin state, stop only owned test processes/forwards, and
archive observed results and remaining limitations.

## Results

The isolated APK built successfully and was installed as
`net.tadel.reaprime.localtest`, version `0.8.8-shot-upload-smoke`, version code
2970. Its signer matches the previous test app. The packaged uploader bytes
match the reviewed source. The six uninstrumented host files match the
workspace exactly; the VM's loaded notification-widget and harness sources also
match their staged sources exactly. The test helper passes static analysis.

The user closed regular Decaid; a zero-I/O loopback check confirmed port 8080
was free even though Android retained its cached process. The test app's device
inventory contained only connected MockDe1 and MockScale, with real discovery
excluded by the staged bootstrap. No physical functions were triggered.

The full Android run passed:

- HTTP 403 produced a visible native serial-specific Support notice. Repeated
  synthetic shot events did not repeat the rejected upload or notification.
- Support opened the actual Samsung browser custom tab. The app was observed
  paused there, then resumed after the test backend linked the serial. Native
  ownership refresh resumed the pending synthetic upload without a restart.
- HTTP 401 invalidated the native account and produced the Sign In notice.
  Its action opened the real AccountPage and DecentLoginForm. Login with fake
  credentials restored native authentication and resumed the synthetic upload.

Counters recorded three in-memory upload attempts: one rejected ownership
attempt and two successful recovery attempts. No upload request left the fake
HTTP client. No real credentials, persisted shots, or machine settings were
used. Screenshots and structured snapshots are saved only in the ignored lab
runtime directory. No new unhandled promise or Flutter framework exceptions
were recorded in the final run.

The run found a real visibility defect: the existing day-long update snackbar
kept an authentication pause queued and invisible. Upload pause notices now
clear the snackbar queue before displaying, matching the host's existing
priority-message pattern. A new regression failed before this change and
passed afterward; the full Android sequence then passed. The latest pause
supersedes earlier snackbar messages rather than waiting behind them.

Fourteen focused Flutter tests passed. The full suite finished with 4,474
passed, two skipped, and the known Windows export path-separator failure.
Analysis reported only the six existing reliability-audit warnings.

Test-only plugin runtime settings and its auto-load preference were restored;
credentials and upload records remained in memory. The test app was stopped,
and only the two created ADB forwards and temporary device screenshot were
removed. Regular Decaid was not restarted, replaced, or modified during this
full-build stage. The instrumented Decaid Test APK remains installed and
stopped; it is a smoke harness, not a production-account build.

## Limits

These tests verify the full Android host with controlled responses, not real
backend rejection policies or a release-signed APK. Real account ownership and
duplicate suppression were checked separately in regular Decaid. Desktop
browser-return behavior, release publishing, and the bundled-version update
remain outside this check.
