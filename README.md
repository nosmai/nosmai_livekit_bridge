# Nosmai LiveKit Bridge

Publish a **Nosmai-filtered camera feed** to a LiveKit room from Flutter — AR effects,
beauty and background segmentation, at full frame rate, with no per-frame copies.

| Platform | Status | Frame path | Measured |
|---|---|---|---|
| Android | Supported (minSdk 24) | GPU texture in a shared EGL group | ~30 fps @ 720×1280, Pixel 5 |
| iOS | Supported (iOS 15+) | IOSurface-backed `CVPixelBuffer` | ~30 fps @ 720×1280, iPhone 15 |

---

## The model: Nosmai owns the camera, LiveKit publishes

This is the one thing to understand before using the plugin.

```
Camera ──► Nosmai (filters + AR) ──┬──► on-screen preview   (NosmaiCameraPreview)
                                   └──► LiveKit encoder     (this plugin)
```

**Your app must mount a `NosmaiCameraPreview`, and must not create a LiveKit camera
track.** That is not a style preference — three things depend on it:

- `NosmaiCameraPreview` creates the platform view Nosmai's `startProcessing()` waits
  for. Without it, processing silently defers and **no frames are ever produced**.
- Mounting it sets the SDK's current GL view. Without that, `applyFilter` fails with
  *"Cannot apply filter: GL preview is unavailable"*. Unmounting clears it again, so
  it must stay mounted for the whole session.
- Calling `LocalVideoTrack.createCameraTrack()` opens a **second camera**, and a second
  Nosmai pipeline that contends for the same GL worker. Measured cost: roughly **a third**
  of the achievable frame rate.

LiveKit still owns everything it should — the room, signalling, publishing, subscriptions.
It just doesn't capture.

---

## Install

```yaml
dependencies:
  nosmai_livekit_bridge:
    git:
      url: https://github.com/nosmai/nosmai_livekit_bridge.git
  nosmai_camera_sdk: ^3.0.6
  livekit_client: ^2.6.4
```

### Android

The Nosmai SDK ships as an AAR that the **host app** must bundle (the plugin declares it
`compileOnly`, so it isn't duplicated):

```kotlin
// android/app/build.gradle.kts
dependencies {
    implementation(files("libs/nosmai-release.aar"))
}
```

Permissions are merged in from the plugin. Nosmai licence keys are bound to your
`applicationId`, so set it to the id your key was issued for.

### iOS

Minimum deployment target **15.0** (`nosmai_camera_sdk` requires it):

```ruby
# ios/Podfile
platform :ios, '15.0'
```

Add to `ios/Runner/Info.plist`:

```xml
<key>NSCameraUsageDescription</key>
<string>Camera access is needed to apply live filters.</string>
<key>NSMicrophoneUsageDescription</key>
<string>Microphone access is needed to publish audio.</string>
```

iOS keys are bound to your bundle id, and are **different from your Android key**.

---

## Usage

```dart
// 1. BEFORE Nosmai initializes.
//    On Android this joins flutter_webrtc's EGL share group so Nosmai's output
//    textures are usable by the encoder. Called late, it is ignored and the
//    remote silently shows black. No-op on iOS.
await NosmaiLiveKitBridge.registerShareContext();
await NosmaiFlutter.initialize(licenseKey);

// 2. Nosmai owns the screen. This widget is required (see above).
@override
Widget build(BuildContext context) => const NosmaiCameraPreview();

// 3. Publish. One call mints the track; you publish it as usual.
final track = await NosmaiLiveKitBridge.createVideoTrack();

final room = Room(
  roomOptions: const RoomOptions(
    stopLocalTrackOnUnpublish: false,                                // see Gotchas
    defaultVideoPublishOptions: VideoPublishOptions(simulcast: false),
  ),
);
await room.connect(url, token);
await room.localParticipant!.publishVideoTrack(track);

// 4. Filters apply through the Nosmai SDK, live, while streaming.
await NosmaiFlutter.instance.applyFilter(filterPath);

// 5. Camera switching goes through NOSMAI, never LiveKit.
await NosmaiFlutter.instance.switchCamera();

// 6. Teardown — stop producing before leaving the room.
await NosmaiLiveKitBridge.stopStreaming();
await room.disconnect();
```

---

## API

| Method | Purpose |
|---|---|
| `registerShareContext()` | Join the encoder's EGL share group. **Call before `NosmaiFlutter.initialize`.** No-op on iOS. |
| `createVideoTrack()` | Mint a `LocalVideoTrack` carrying Nosmai's filtered output, ready to publish. |
| `stopStreaming()` | Stop producing and release the track. Call **before** disconnecting. |
| `isStreaming()` | Whether frames are currently being published. |
| `setRotation(degrees)` | Rotation metadata (0/90/180/270). Default `0` is correct; the receiver applies it, so changing it is free. |
| `startStreaming()` | Lower-level: returns `{trackId, label}` without wrapping. Prefer `createVideoTrack()`. |

---

## Gotchas

**Order is load-bearing at startup.** `registerShareContext()` must complete before
`NosmaiFlutter.initialize()`. The share handle is consumed when Nosmai's GL context is
constructed; a late call is ignored, Nosmai gets a standalone context, and the remote
shows black **with no error anywhere**.

**Don't let LiveKit touch the camera.** Avoid `setCameraEnabled`, `setCameraPosition`,
`switchCamera`, `restartTrack` and bare `mute()`/`unmute()` — they re-run `getUserMedia`
and replace the filtered track with a raw camera track.

**`stopLocalTrackOnUnpublish: false`.** The track's lifetime belongs to Nosmai; letting
LiveKit stop it disposes a native object the plugin still owns.

**Simulcast off, at least initially.** Each layer needs a differently-scaled copy, which
for a texture buffer risks a GPU→CPU conversion per layer — silently reintroducing the
readback this plugin exists to avoid.

**One camera.** If you see roughly a third of the expected frame rate, something in your
app is still creating a LiveKit camera track.

---

## Testing locally

No cloud account needed:

```bash
brew install livekit livekit-cli
livekit-server --dev --bind 0.0.0.0

lk token create --api-key devkey --api-secret secret \
  --join --room my-room --identity phone --valid-for 720h
```

Use your machine's **LAN IP** (not `localhost`) in the app — a phone cannot reach the
host otherwise. Note that restarting `--dev` regenerates its signing key, so previously
minted tokens start failing with a bare 401.

`tools/livekit-viewer/index.html` is a minimal browser viewer for checking the published
stream. Unlike the LiveKit meet demo it shows the frame with `object-fit: contain`, so a
portrait stream is never cropped, and it displays live resolution, orientation, fps and
codec. Serve it over plain `http://` — `ws://` is blocked as mixed content from `https://`:

```bash
cd tools/livekit-viewer && python3 -m http.server 8090
```

---

## How it works

**Android.** The plugin joins flutter_webrtc's EGL share group, mints a `VideoSource`/
`VideoTrack` from its `PeerConnectionFactory`, and registers the track so Dart-side
lookups resolve. Nosmai delivers each filtered frame as a GL texture; the plugin blits it
**once** into a WebRTC-owned texture on the helper's GL thread and hands it to the
capturer observer. No readback, no colour conversion, no CPU copies.

**iOS.** No EGL, so no share context. Nosmai delivers finished `CVPixelBuffer`s, which are
IOSurface-backed — wrapping one in an `RTCCVPixelBuffer` is a refcount bump. The plugin
mints an `RTCVideoSource`/`RTCVideoTrack` and pushes frames straight through.

The same Dart API covers both; the asymmetry is inherent to the platforms.

---

## Licence

See [LICENSE](LICENSE).
