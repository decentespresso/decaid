# Shot Upload Account Status

## Goal

Show the Decent account authentication state in the Decent shot upload plugin's
native settings dialog. When the account is not authenticated, provide a direct
path to the native Account page.

## Current path

- `PluginsSettingsView` renders plugin settings from each manifest.
- The shot uploader declares `proxy.decent_api.write`, which identifies it as a
  Decent-account consumer without hard-coding its plugin id.
- `DecentAccountService.isLoggedIn()` already reports the credential-validated
  state and deliberately exposes neither the email nor credentials.
- `MyApp` already owns that service and registers `AccountPage.routeName`.
- The shot uploader source is published from `decentespresso/shot-upload`, but
  this UI belongs to Decaid's generic native plugin-settings host. No standalone
  plugin change or release is needed.

## Plan

1. Add widget coverage in `test/plugins_settings_view_appstore_test.dart` before
   changing the UI:
   - an account-proxy plugin reports `Logged in` when the injected account
     service returns true;
   - it reports `Not logged in` and shows an Account-page action when false;
   - activating that action closes the settings dialog, does not save pending
     plugin settings, and navigates to `AccountPage.routeName`.
2. Pass the existing optional `DecentAccountService` from `MyApp` into
   `PluginsSettingsView`.
3. For manifests with `proxy.decent_api` or `proxy.decent_api.write`, start one
   cached `isLoggedIn()` future when the settings dialog opens and render its
   loading, authenticated, unauthenticated, and unavailable states above the
   existing controls.
4. In the unauthenticated state, use the existing native Account route. Close
   the dialog before navigating so reopening the plugin settings after login
   performs a fresh status check.
5. Keep the existing settings Save and Cancel behavior unchanged, then archive
   this plan under `doc/plans/archive/shot-upload-account-status/` before the
   implementation PR is marked ready.

## Verification

```text
dart format lib test
flutter test test/plugins_settings_view_appstore_test.dart
flutter analyze
flutter test
```

Manually verify `Settings > Plugins > Decent shot upload > Settings` with an
authenticated and unauthenticated account, including navigation to Account and
the refreshed state after returning and reopening the dialog.

## Acceptance criteria

- The shot uploader settings identify the account as `Logged in` or
  `Not logged in` from `DecentAccountService.isLoggedIn()`.
- An unauthenticated user can open the native Account page from that dialog.
- No email, password, proxy token, or new login/logout network route is exposed.
- Plugins without a Decent-account proxy permission keep their current UI.
- Opening Account does not implicitly persist unsaved plugin settings.

## Out of scope

- Changes to upload, retry, or reconciliation behavior.
- A custom plugin UI or plugin-manifest schema extension.
- Changes to the account REST contract or the external shot uploader package.
