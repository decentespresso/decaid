## Summary

- Stop retry storms for unlinked machine serials in the shot-upload source repository.
- Add Decaid account-change delivery, structured authentication failures, and native pause notices with support/sign-in actions.

## Linked Issue

Related https://github.com/decentespresso/shot-upload/issues/2

## Verification

- Review follow-up: all six supplied findings addressed; 68 Node tests, 258 focused native tests, and two native smoke checks passed. Analysis is clean; full suite is 4,970 passed, two skipped, and the same seven Windows baseline failures. See `review-fixes.md` for failing-before-fix evidence and scope. These fixes are follow-up commits for the same two draft PRs, not a release or bundle-pin update.
- Isolated main-based branches on 2026-10-16: 59 Node tests and 14 focused Flutter regressions passed; host analysis found no issues and formatting changed no affected Dart files.
- Isolated host full suite: 4,965 passed, two skipped, seven BigInt-related scale-test failures. All seven reproduce on unchanged main `b9f9d055` with the same Windows runtime (24 passed, seven failed in the two scale suites). No unrelated scale/runtime changes are included.

Earlier source/device checks below predate the current-main port:

- 59 JavaScript tests passed; 176 focused Flutter tests passed, including six native proxy authentication-generation regressions.
- Two native QuickJS source-plugin smoke checks passed with a mocked upstream, including host auth-failure event ordering. No real account or machine was used.
- Plugin-only live tablet check on 2026-10-15: local 0.2.4 loaded in regular Decaid 0.8.8; authenticated ownership lookup and duplicate suppression passed, all 75 shots and login/settings/history were preserved, and no additional shot-upload POST occurred. The write-blocked probe was removed and exact reviewed source restored. Automatic uploads remained off.
- Full Android Decaid Test smoke passed with an in-memory account/backend: serial pause and repeat suppression, real Support browser return and refresh, native Sign In navigation and login recovery. It found an upload notice hidden behind the day-long update banner; the notice now takes priority, with a new failing-then-passing regression. Fourteen focused tests passed after the correction. No real uploads or physical functions occurred; the test app was stopped afterward.
- Astra xhigh re-reviewed the three corrected findings and the native stale-401 guard and found no remaining actionable defects in those fixes.
- Full Flutter suite: 4,474 passed, 2 skipped, 1 known Windows export path-separator failure.
- `lib` and `test` analysis found no issues. Repository-wide analysis has six pre-existing reliability-audit warnings.
- Raw diffs and relevant diagnostics inspected; whitespace checks passed.

## Impact

- Pauses are per serial for ownership failures and account-wide for authentication failures. Machine-list outages hold uploads with backoff without a false ownership notice.
- Existing shots, original serials, and document-rejection behavior are preserved. No database migration or core REST/WebSocket wire-shape change is required.
- Plugin status and event additions are documented in its README and `doc/Plugins.md`. Credentials remain in the host proxy; account-change events require the existing read permission and contain no account identity.
- Delivery is split into linked draft PRs for the source uploader and native host support. The plugin release and checksum-verified Decaid bundle pin update remain pending; generated bundled assets were not edited.
- Historical ownership policy, customer upgrade communication, and release-signed live-account host verification remain maintainer/support work. Local signing keys do not match the installed regular app, so its host build was not replaced.
- Android browser-return and sign-in recovery passed with controlled responses; desktop browser-return behavior remains an unverified platform check.

## Contributor Responsibility

- [ ] I have reviewed and understand all changes in this PR and take responsibility for their correctness, security, behavior, licensing, and provenance, including any AI-assisted or AI-generated work. <!-- contributor-responsibility -->

The human submitter must complete this declaration before marking the draft ready
for review. The declaration remains unchecked in the draft.
