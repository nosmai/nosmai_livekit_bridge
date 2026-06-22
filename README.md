# nosmai_livekit_bridge

Add real-time **Nosmai beauty filters** to a **LiveKit** camera stream in Flutter — **without writing native code**. Your app keeps full control of the LiveKit `Room` and the camera track; this package attaches a native frame processor that runs Nosmai on every frame before it reaches the encoder and the local preview.

## Features

- **No native code** – attach filters to a LiveKit track with a couple of Dart calls.
- **You own LiveKit** – keep using `livekit_client` exactly as you do today (`Room`, `LocalVideoTrack`, `VideoTrackRenderer`).
- **Processed everywhere** – the filtered frame is what gets published *and* what your local preview shows.
- **Cross-platform** – Android (✅ working) and iOS (🚧 experimental).

## How it differs from a "shared handle" bridge

Unlike an Agora-style bridge (where native owns the whole pipeline behind a shared handle), LiveKit's `livekit_client` already runs the camera and the WebRTC pipeline in Dart on top of `flutter_webrtc`. So this bridge does **not** take over the pipeline — it hooks into it:

```
┌─────────────────────────── Flutter (your app) ───────────────────────────┐
│  livekit_client                                                          │
│   • LocalVideoTrack.createCameraTrack()   ← you create the track         │
│   • Room().connect() / publishVideoTrack  ← you connect & publish        │
│   • VideoTrackRenderer                     ← you render the preview       │
└───────────────┬───────────────────────────────────────────────────────────┘
                │  attachNosmaiProcessing(trackId)
                ▼
┌─────────────────────── nosmai_livekit_bridge (native) ───────────────────┐
│  Android: LocalVideoTrack.addProcessor(ExternalVideoFrameProcessing)     │
│  iOS:     LocalVideoTrack.addProcessing(ExternalVideoProcessingDelegate) │
│                         │ every camera frame                              │
│                         ▼                                                 │
│                   Nosmai SDK (reflection / runtime)                       │
│                         │ filtered frame (in place)                       │
│                         ▼                                                 │
│              flutter_webrtc encoder + local renderer                      │
└───────────────────────────────────────────────────────────────────────────┘
```

The Nosmai SDK itself is reached **at runtime** (reflection on Android, selector lookup on iOS), so this package has **no compile-time dependency** on the Nosmai SDK.

## Platform support

| Platform | Status | Notes |
|----------|--------|-------|
| Android  | ✅ Working | I420 frame processing; grey-frame, OOM, and camera-switch issues resolved. |
| iOS      | ✅ Working | NV12↔BGRA conversion implemented; filters apply correctly. |

## Installation

Add the package to your app's `pubspec.yaml`, alongside `livekit_client` and the Nosmai SDK:

```yaml
dependencies:
  nosmai_livekit_bridge:
    git:
      url: https://github.com/nosmai/nosmai_livekit_bridge.git

  livekit_client: ^2.6.4
  nosmai_camera_sdk: ^3.0.5
```

Then:

```bash
flutter pub get
```

That's it for the bridge wiring — the plugin registers itself and brings its own native build configuration (it depends on `flutter_webrtc`, which `livekit_client` already uses, and compiles against it internally). You do **not** need to add any `org.webrtc` / WebRTC Gradle lines to your app.

### Platform setup

You still need the standard camera/mic setup that LiveKit and Nosmai require:

**Android** (`android/app/src/main/AndroidManifest.xml`):

```xml
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
```

`android/app/build.gradle(.kts)` — `minSdk` 24 or higher:

```kotlin
defaultConfig {
    minSdk = 24
}
```

**iOS** (`ios/Runner/Info.plist`):

```xml
<key>NSCameraUsageDescription</key>
<string>This app needs camera access to stream video.</string>
<key>NSMicrophoneUsageDescription</key>
<string>This app needs microphone access to stream audio.</string>
```

Set the iOS deployment target to **13.0+** (Podfile `platform :ios, '13.0'`).

> **Nosmai SDK runtime:** the bridge calls the Nosmai SDK at runtime via the classes registered by `nosmai_camera_sdk`. Follow the `nosmai_camera_sdk` setup so its native runtime is present in your app; the bridge does not bundle it.

## Usage

### 1. Initialize the Nosmai SDK

```dart
import 'package:nosmai_camera_sdk/nosmai_camera_sdk.dart';

await NosmaiFlutter.initialize('YOUR_NOSMAI_LICENSE_KEY');
```

### 2. Create a LiveKit camera track

```dart
import 'package:livekit_client/livekit_client.dart';

final track = await LocalVideoTrack.createCameraTrack(
  const CameraCaptureOptions(cameraPosition: CameraPosition.front),
);
```

### 3. Attach Nosmai processing to that track

```dart
import 'package:nosmai_livekit_bridge/nosmai_livekit_bridge.dart';

await NosmaiLiveKitBridge.attachNosmaiProcessing(
  videoTrackId: track.mediaStreamTrack.id!,
  isFrontCamera: true,
);
```

### 4. Connect and publish — normal LiveKit

```dart
final room = Room();
await room.connect('wss://your-server.livekit.cloud', token);
await room.localParticipant?.publishVideoTrack(track);
```

### 5. Render the local preview — normal LiveKit

```dart
VideoTrackRenderer(track) // shows the filtered output (same as remote viewers)
```

### 6. Apply / change filters through the Nosmai SDK

```dart
final filters = await NosmaiFlutter.instance.getLocalFilters();
await NosmaiFlutter.instance.applyFilter(filters.first.path);

// Beauty filters
await NosmaiFlutter.instance.applySkinSmoothing(5.0);
await NosmaiFlutter.instance.applyFaceSlimming(3.0);

await NosmaiFlutter.instance.removeAllFilters();
```

### 7. Switch camera

```dart
await track.setCameraPosition(CameraPosition.back);
// Re-attach so Nosmai re-initialises for the new camera.
await NosmaiLiveKitBridge.attachNosmaiProcessing(
  videoTrackId: track.mediaStreamTrack.id!,
  isFrontCamera: false,
);
```

### 8. Cleanup

```dart
await NosmaiLiveKitBridge.releaseNosmaiProcessing();
await track.stop();
await room.disconnect();
```

## Complete example

```dart
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:nosmai_camera_sdk/nosmai_camera_sdk.dart';
import 'package:nosmai_livekit_bridge/nosmai_livekit_bridge.dart';
import 'package:permission_handler/permission_handler.dart';

class LiveKitStreamingScreen extends StatefulWidget {
  const LiveKitStreamingScreen({super.key});

  @override
  State<LiveKitStreamingScreen> createState() => _LiveKitStreamingScreenState();
}

class _LiveKitStreamingScreenState extends State<LiveKitStreamingScreen> {
  Room? _room;
  LocalVideoTrack? _track;
  bool _isFront = true;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    await [Permission.camera, Permission.microphone].request();

    // 1. Nosmai SDK must be initialized (e.g. at app start).
    if (!NosmaiFlutter.instance.isInitialized) {
      await NosmaiFlutter.initialize('YOUR_NOSMAI_LICENSE_KEY');
    }

    // 2. Create the LiveKit camera track.
    final track = await LocalVideoTrack.createCameraTrack(
      const CameraCaptureOptions(cameraPosition: CameraPosition.front),
    );
    _track = track;

    // 3. Attach Nosmai filtering.
    await NosmaiLiveKitBridge.attachNosmaiProcessing(
      videoTrackId: track.mediaStreamTrack.id!,
      isFrontCamera: true,
    );

    // 4. Connect + publish.
    final room = Room();
    _room = room;
    await room.connect('wss://your-server.livekit.cloud', 'YOUR_TOKEN');
    await room.localParticipant?.publishVideoTrack(track);

    if (mounted) setState(() {});
  }

  Future<void> _switchCamera() async {
    final track = _track;
    if (track == null) return;
    _isFront = !_isFront;
    await track.setCameraPosition(_isFront ? CameraPosition.front : CameraPosition.back);
    await NosmaiLiveKitBridge.attachNosmaiProcessing(
      videoTrackId: track.mediaStreamTrack.id!,
      isFrontCamera: _isFront,
    );
  }

  @override
  void dispose() {
    NosmaiLiveKitBridge.releaseNosmaiProcessing();
    _track?.stop();
    _room?.disconnect();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          if (_track != null) VideoTrackRenderer(_track!),
          Positioned(
            bottom: 32,
            right: 24,
            child: FloatingActionButton(
              onPressed: _switchCamera,
              child: const Icon(Icons.cameraswitch),
            ),
          ),
        ],
      ),
    );
  }
}
```

## API reference

### `NosmaiLiveKitBridge`

| Method | Description | Returns |
|--------|-------------|---------|
| `attachNosmaiProcessing({required String videoTrackId, bool isFrontCamera = true})` | Attach Nosmai filtering to a flutter_webrtc/LiveKit camera track. | `Future<void>` |
| `updateNosmaiCameraFacing({required bool isFrontCamera})` | Tell Nosmai which camera is active (mirroring/orientation). | `Future<void>` |
| `releaseNosmaiProcessing()` | Detach the processor and release its resources. | `Future<void>` |
| `getPlatformVersion()` | Host platform version (sanity check). | `Future<String?>` |

## Known issues

- **Camera facing & Nosmai:** the bridge always tells Nosmai "back camera" and lets the renderer mirror cosmetically, because Nosmai's front-camera in-place flip corrupts the frame data (grey frames on Android, artifacts on iOS). Selfie mirror is therefore a `VideoTrackRenderer` concern, not a Nosmai one.
- **iOS front-camera mirroring:** the selfie mirror is handled by the renderer (`VideoTrackRenderer`), not by Nosmai. Ensure your renderer has `mirrorMode` set appropriately for the front camera.

## Troubleshooting

| Symptom | Likely cause / fix |
|---------|--------------------|
| Stream shows raw camera (no filter) | `attachNosmaiProcessing` not called, or called before the track existed. Attach using `track.mediaStreamTrack.id` right after `createCameraTrack`. |
| Filter lost after switching camera | Re-call `attachNosmaiProcessing` (or `updateNosmaiCameraFacing`) after `setCameraPosition`. |
| Grey / corrupted video (Android) | Ensure you're on this package's processor (it packs planes into tight buffers). Don't tell Nosmai "front camera". |
| Crash / OOM after ~1 min (Android) | Make sure you're using this package unmodified — it defers `VideoFrame` release by one frame to avoid leaking I420 buffers. |
| `FlutterWebRTCPlugin not initialized` | Create at least one flutter_webrtc/LiveKit track before attaching. |
| iOS shows unfiltered video | Check console for `[NosmaiVideoProcessor]` logs. Ensure `nosmai_camera_sdk` is properly initialized before attaching. |
| Selfie appears un-mirrored | Set `mirrorMode` on your `VideoTrackRenderer` for front camera. The bridge doesn't mirror; the renderer does. |

## License

MIT License — see [LICENSE](LICENSE).

## Credits

- Built for [LiveKit](https://livekit.io/)
- Powered by [Nosmai Camera SDK](https://nosmai.com/)
