# Camera Audit Test skin

Manual device-acceptance skin for per-skin live camera consent and file-input
capture (PR #939 and the iOS/macOS extension of it). No automated test consumes
this directory; it exists so a tester can exercise the WebView gate on real
hardware without writing a skin first.

Contents: `index.html`, `skin-manifest.json` (skin id `camera-audit-test`).

## Build the installable zip

```sh
cd test_assets
zip -r -X /tmp/camera-audit-test.zip skin_camera_audit -x '*.DS_Store'
```

## Install on iPhone

The app only issues camera consent for an **installed** skin whose served path is
inside its WebUI directory (`cameraTarget` resolves from `installedSkins` in
`lib/src/app.dart`). Live-edit folder serving reports no target, so every camera
request is denied and the gate cannot be exercised. Use one of:

**A. Files / AirDrop**

1. AirDrop the zip to the iPhone, save to Files.
2. Decaid: Skins page -> Install skin -> ZIP file -> pick the zip.
3. Select "Camera Audit Test" and open it.

**B. Install from URL over the LAN (no file copying)**

```sh
cd test_assets
python3 -m http.server 8123
# find the phone IP in Decaid's Skins page, then, with a "Manage plugins and
# skins" token from Decent Account > API access tokens in $TOKEN:
curl -X POST "http://<PHONE_IP>:8080/api/v1/webui/skins/install/url" \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"url":"http://<MAC_IP>:8123/camera-audit-test.zip"}'
```

Reload the skin list, select "Camera Audit Test", open.

**Second instance for per-skin isolation** (skins are keyed by manifest id):

```sh
cd test_assets
cp -R skin_camera_audit skin_camera_audit_b
sed -i '' 's/camera-audit-test/camera-audit-test-b/; s/Camera Audit Test/Camera Audit Test B/' \
  skin_camera_audit_b/skin-manifest.json
zip -r -X /tmp/camera-audit-test-b.zip skin_camera_audit_b >/dev/null
```

## Consent control

Skins page -> select the skin -> **Live camera access** = Ask / Allow / Deny.
This is `SkinCameraConsentSetting` (`lib/src/skin_feature/skin_camera_controls.dart`)
over the `skinCameraConsent.<skinId>` SharedPreferences key.

## Checklist

The skin logs every result with a timestamp; "Copy log" puts it on the clipboard
for pasting into the PR. A screenshot of the log plus the preview is the evidence.

| Case | Where | Expect |
| --- | --- | --- |
| `video: true` with consent = Ask | Live camera | Decaid dialog "Allow "Camera Audit Test"..." then the iOS camera prompt, then a live preview. Log: `GRANTED`, a track line with `facing=`, resolution, fps, and `enumerateDevices -> n videoinput` |
| Same request again on the same page | Live camera | No new Decaid dialog; the stored decision is reused |
| Same request after `Reload skin` | Live camera | Stored Allow resolves silently; stored Deny is refused without prompting; Ask prompts again |
| `audio: true` / `video+audio` | Live camera (red) | `DENIED (expected)` with `NotAllowedError`. No microphone prompt, no shared camera dialog |
| `front (user)` / `back (environment)` | Live camera | Preview switches camera; `facing` in the track line matches |
| `Stop all tracks` | Live camera | Track lines report stop, preview clears; stored consent is unchanged |
| Consent = Deny, then `video: true` | Live camera | Refused with no dialog (stored Deny suppresses the prompt) |
| Consent = Allow, then OS camera permission revoked while the skin is open | Settings > Privacy > Camera | Next request fails; Decaid does not re-grant |
| Consent = Allow, then navigate away and back | Skin switching | A fresh page load must re-request; no stale grant |
| Cancel the Decaid dialog, or background the app during the prompt | Live camera | Request is denied, not granted; a later request re-prompts |
| `accept="image/*"` | Import from library | iOS system picker (Photos/Files) returns a file; log shows name, type, size, preview dimensions |
| Cancel the picker | Import from library | `CANCELLED by user` where WebKit fires the `cancel` event; no file delivered and no error |
| `accept=".jpg"` | Import from library | Picker offers/accepts jpg; a `.png` is not delivered as jpg |
| `accept="image/*"` multiple | Import from library | Multiple files returned |
| `capture="environment"` / `"user"` with `accept="image/*"` | One-shot capture | Android: fresh Decaid confirmation, then camera, then the capture file. iOS: WKWebView's own picker; the per-capture gate does not apply (documented, not a defect) |
| `accept="image/jpeg,.jpg"` + capture | One-shot capture | Accepted on Android |
| `accept="video/*"` + capture | One-shot capture | Android: denied, no confirmation, no picker. iOS: native video recorder can ask for camera and microphone permission; recorded video can include audio after OS consent. No TCC privacy kill |
| Deny microphone permission or cancel native video capture | One-shot capture | No process termination; record whether WebKit reports cancellation, denial or a selected file. No change to stored live-camera consent |
| OS microphone permission granted for native recording, then `audio: true` / `video+audio` | Live camera (red) | Still `DENIED (expected)`; native recording consent does not grant a live microphone stream |
| `accept="video/*"` without capture, or an unrestricted file input | Native file picker | On iOS, exercise any camera recording option as well as importing an existing file; recording, denial and cancellation must not terminate the app |
| Per-skin isolation (skin B above) | Both skins | Consent set on skin A does not leak to skin B; each id keeps its own `skinCameraConsent.*` entry |

Not covered here: a genuinely untrusted non-localhost origin, macOS sandboxed
builds, WebKit content-process termination, and the CocoaPods vs SPM build paths.
