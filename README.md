# Nosmai LiveKit Bridge

A Flutter plugin that adds real-time Nosmai beauty filters to LiveKit video streams. Apply filters to your camera track with just a few lines of Dart code while keeping full control of your LiveKit Room and video tracks.

## Features

- Apply Nosmai beauty filters to LiveKit camera streams
- Works with your existing LiveKit setup (Room, LocalVideoTrack, VideoTrackRenderer)
- Filtered video appears in both local preview and published stream
- Supports Android and iOS

## Platform Support

| Platform | Status |
|----------|--------|
| Android  | Supported (minSdk 24) |
| iOS      | Supported (iOS 13.0+) |

## Installation

Add the following to your `pubspec.yaml`:

```yaml
dependencies:
  nosmai_livekit_bridge:
    git:
      url: https://github.com/nosmai/nosmai_livekit_bridge.git

  livekit_client: ^2.6.4
  nosmai_camera_sdk: ^3.0.5
```

Then run:

```bash
flutter pub get
```

### Android Setup

Add these permissions to `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.CAMERA" />
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
```

Set the minimum SDK version in `android/app/build.gradle`:

```kotlin
defaultConfig {
    minSdk = 24
}
```

### iOS Setup

Add these entries to `ios/Runner/Info.plist`:

```xml
<key>NSCameraUsageDescription</key>
<string>This app needs camera access to stream video.</string>
<key>NSMicrophoneUsageDescription</key>
<string>This app needs microphone access to stream audio.</string>
```

Set the deployment target in your Podfile:

```ruby
platform :ios, '13.0'
```

Make sure the Nosmai Camera SDK is properly set up in your project by following the `nosmai_camera_sdk` installation guide.

## Usage

### Step 1: Initialize the Nosmai SDK

```dart
import 'package:nosmai_camera_sdk/nosmai_camera_sdk.dart';

await NosmaiFlutter.initialize('YOUR_NOSMAI_LICENSE_KEY');
```

### Step 2: Create a LiveKit Camera Track

```dart
import 'package:livekit_client/livekit_client.dart';

final track = await LocalVideoTrack.createCameraTrack(
  const CameraCaptureOptions(cameraPosition: CameraPosition.front),
);
```

### Step 3: Attach Nosmai Processing

```dart
import 'package:nosmai_livekit_bridge/nosmai_livekit_bridge.dart';

await NosmaiLiveKitBridge.attachNosmaiProcessing(
  videoTrackId: track.mediaStreamTrack.id!,
  isFrontCamera: true,
);
```

### Step 4: Connect and Publish

```dart
final room = Room();
await room.connect('wss://your-server.livekit.cloud', token);
await room.localParticipant?.publishVideoTrack(track);
```

### Step 5: Render the Preview

```dart
VideoTrackRenderer(track)
```

### Step 6: Apply Filters

```dart
final filters = await NosmaiFlutter.instance.getLocalFilters();
await NosmaiFlutter.instance.applyFilter(filters.first.path);

// Beauty filters
await NosmaiFlutter.instance.applySkinSmoothing(5.0);
await NosmaiFlutter.instance.applyFaceSlimming(3.0);

// Remove all filters
await NosmaiFlutter.instance.removeAllFilters();
```

### Step 7: Switch Camera

When switching cameras, re-attach Nosmai processing:

```dart
await track.setCameraPosition(CameraPosition.back);

await NosmaiLiveKitBridge.attachNosmaiProcessing(
  videoTrackId: track.mediaStreamTrack.id!,
  isFrontCamera: false,
);
```

### Step 8: Cleanup

```dart
await NosmaiLiveKitBridge.releaseNosmaiProcessing();
await track.stop();
await room.disconnect();
```

## Complete Example

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

    // Initialize Nosmai SDK
    if (!NosmaiFlutter.instance.isInitialized) {
      await NosmaiFlutter.initialize('YOUR_NOSMAI_LICENSE_KEY');
    }

    // Create the camera track
    final track = await LocalVideoTrack.createCameraTrack(
      const CameraCaptureOptions(cameraPosition: CameraPosition.front),
    );
    _track = track;

    // Attach Nosmai filtering
    await NosmaiLiveKitBridge.attachNosmaiProcessing(
      videoTrackId: track.mediaStreamTrack.id!,
      isFrontCamera: true,
    );

    // Connect and publish
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
    await track.setCameraPosition(
      _isFront ? CameraPosition.front : CameraPosition.back,
    );

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

## API Reference

| Method | Description |
|--------|-------------|
| `attachNosmaiProcessing({required String videoTrackId, bool isFrontCamera = true})` | Attach Nosmai filtering to a LiveKit camera track. |
| `updateNosmaiCameraFacing({required bool isFrontCamera})` | Update camera facing direction without re-attaching. |
| `releaseNosmaiProcessing()` | Detach the processor and release resources. |
| `getPlatformVersion()` | Returns the host platform version. |

## Troubleshooting

**Stream shows raw camera without filters**

Make sure you call `attachNosmaiProcessing` after creating the camera track, using `track.mediaStreamTrack.id`.

**Filters stop working after switching camera**

Call `attachNosmaiProcessing` again after `setCameraPosition` to reinitialize the filter pipeline.

**Front camera selfie is not mirrored**

Set `mirrorMode` on your `VideoTrackRenderer` for the front camera. The bridge does not handle mirroring.

**Video appears unfiltered on iOS**

Ensure the Nosmai Camera SDK is properly initialized before attaching processing.

## License

MIT License. See [LICENSE](LICENSE) for details.
