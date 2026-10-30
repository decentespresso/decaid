# Windows Skin Startup Failure

## Evidence And Limits

[Issue #953](https://github.com/decentespresso/decaid/issues/953) supplies a
[historical log](https://gist.github.com/reaprime-bot/c2e974d3da41947f31b8ce8d8fe5d09b),
not access to the affected Windows 10 machine. Its native failure is not
reproduced locally.

On October 3, GitHub release requests first fail with 403 at 20:40:22, but the
embedded page finishes loading at 20:41:28. Later sessions stop before
`onWebViewCreated`. Both Decaid (0.8.7 to 0.8.5) and WebView2
(154.0.4258.37 to 154.0.4258.53) changed between those working and failing
sessions. The log cannot isolate an application, runtime, or profile cause.
Its six scale `Unreachable` failures and four later successful connections are
separate from embedded browser initialization.

The pinned Windows plugin (0.7.0-beta.3) checks runtime availability independently
of native environment/composition-controller creation. Its platform widget
awaits `createInAppWebView` without forwarding creation errors to page-load
callbacks. Native HRESULT debug output is disabled in release builds. Decaid's
spinner previously depended on callbacks that might never arrive. In particular,
the native controller-creation calls only log an immediate failing HRESULT;
they do not complete the pending Dart creation call on that path. Asynchronous
creation failures instead become generic platform exceptions without the
original HRESULT. These are source-level failure mechanisms, not proof of
which path the reporter encountered.

[Upstream #2626](https://github.com/pichillilorenzo/flutter_inappwebview/issues/2626)
documents a similar packaged-app failure resolved by explicitly passing an
environment with a writable profile location. This supports a possible
permission mechanism, not a diagnosis for #953.
[Upstream #2840](https://github.com/pichillilorenzo/flutter_inappwebview/issues/2840)
describes a process crash after creation, unlike the still-running reported
Decaid session. WebView2Feedback #5747 mentions the same runtime version but a
kernel bugcheck on different Windows versions, not this symptom.

## Decision

Bound Windows initial loading to 30 seconds, logging whether creation or page
loading remained incomplete. Show browser/dashboard recovery without removing
the pending WebView; a late successful load restores it. Hide its focus and
semantics while the failure overlay is visible. Cancel the timer on completion
and disposal, and ignore compatibility/page callbacks after disposal.

The maintainer requested improved logging alongside the timeout. Emit correlated
Windows startup records through the existing `SkinView` logger, including skin
ID, local port, creation/page-load stage, monotonic elapsed milliseconds, and
timeout state. Record creation, completion, timeout, late recovery, and disposal
before completion. Stop recording once initial loading completes. This separates
missing native creation from a created browser whose page did not load, without
logging URLs or profile paths. Existing startup logs supply OS, app, and runtime
versions; the pinned plugin still limits visibility into native HRESULT failures.

Review found that switching simulated devices retained the old controller and
loading state while replacing the keyed WebView. Reset that state when switching
and invalidate callbacks from the previous attempt, including delayed renderer
recovery. Preserve the timeout screen if the browser launcher returns false.
Record creation as the page-load stage even when creation and load completion
arrive in the same frame. Inject the compatibility operation through the
constructor so disposal tests await a pending check on Linux as well as Windows;
Flutter's target-platform override does not change `Platform.isWindows`.

Preserve profile locations, browser data, dependency pins, navigation policy,
and security settings. Do not add automatic retries or claim to fix the unknown
native trigger. PR #998 concerns online update-error reporting, not native
WebView initialization. Regression tests inject missing/late callbacks and do
not constitute reproduction of the reporter's environment.
