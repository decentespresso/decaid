# Apple Skin Camera Consent

Extend PR #939's live-camera support to iOS and macOS. Keep Windows and Linux
unchanged and keep Android's file chooser protections.

## Design

Reuse the existing per-installed-skin consent store and permission gate. Grant
only camera-only requests from the currently served skin's localhost origin,
after native consent and the operating system's camera permission. Invalidate
pending grants on navigation, backgrounding, disposal and WebKit termination.

Use the existing permission handler on iOS. On macOS, use a small AVFoundation
method channel because the installed permission handler has no macOS backend.
Add camera usage text and the macOS camera entitlement without requesting
microphone or new gallery permissions.

Apple file-input capture does not expose the Android chooser callback through
the pinned plugin. Leave the Apple system pickers unchanged and document that
the per-skin policy governs live streams, not native file-input capture.

## Verification

The regression-first platform dispatch test failed before the adapter existed.
Focused coverage includes system camera permission dispatch, Apple selector
controls, microphone/mixed-resource denial, stale grants and Android chooser
protections. The focused run passed 91 tests. Flutter analysis reported no
issues; formatting completed. The full Windows run passed 4,479 tests with two
skips using a temporary correction to the pre-existing Windows archive-path
assertion. The correction was restored and is not part of this change.

Another tester must build and test on iPhone/iPad and macOS. The PR must state
that Apple compilation, system prompts, localhost getUserMedia, camera
selection, background/navigation cancellation and file-input behavior remain
unverified on Apple hardware.
