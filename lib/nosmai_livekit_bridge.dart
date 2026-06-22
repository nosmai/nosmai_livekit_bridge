import 'dart:developer' as developer;
import 'package:flutter/services.dart';

/// Nosmai LiveKit Bridge.
///
/// Adds real-time Nosmai beauty filters to a LiveKit camera track. Your app owns
/// the LiveKit [Room] and the camera [LocalVideoTrack] (via `livekit_client`); this
/// bridge attaches a native frame processor that runs Nosmai on every frame before
/// it reaches the encoder and the local preview.
///
/// Typical flow:
/// ```dart
/// // 1. Initialize the Nosmai SDK once at app start.
/// await NosmaiFlutter.initialize('YOUR_NOSMAI_LICENSE_KEY');
///
/// // 2. Create a LiveKit camera track.
/// final track = await LocalVideoTrack.createCameraTrack(
///   CameraCaptureOptions(position: CameraPosition.front),
/// );
///
/// // 3. Attach Nosmai processing to that track.
/// await NosmaiLiveKitBridge.attachNosmaiProcessing(
///   videoTrackId: track.mediaStreamTrack.id!,
///   isFrontCamera: true,
/// );
///
/// // 4. Connect + publish as usual with livekit_client.
/// final room = Room();
/// await room.connect(url, token);
/// await room.localParticipant?.publishVideoTrack(track);
///
/// // 5. Apply filters through the Nosmai SDK.
/// await NosmaiFlutter.instance.applyFilter(filterPath);
///
/// // 6. Tear down.
/// await NosmaiLiveKitBridge.releaseNosmaiProcessing();
/// ```
class NosmaiLiveKitBridge {
  NosmaiLiveKitBridge._();

  static const MethodChannel _channel = MethodChannel('nosmai_livekit_bridge');

  /// Attaches Nosmai beauty-filter processing to a `flutter_webrtc` camera track.
  ///
  /// Call this after [LocalVideoTrack.createCameraTrack] returns, passing the
  /// track ID from `track.mediaStreamTrack.id`.
  ///
  /// * Android: adds an `ExternalVideoFrameProcessing` to flutter_webrtc's
  ///   pipeline — every frame is processed by Nosmai before reaching the encoder
  ///   and the renderer.
  /// * iOS: adds an `ExternalVideoProcessingDelegate` that modifies the
  ///   `CVPixelBuffer` in place; the shared buffer reference means the WebRTC
  ///   encoder sees the processed result.
  ///
  /// [isFrontCamera] tells Nosmai which camera is active so it applies the
  /// correct orientation/mirroring.
  static Future<void> attachNosmaiProcessing({
    required String videoTrackId,
    bool isFrontCamera = true,
  }) async {
    developer.log(
      '[NosmaiLiveKitBridge] Attaching Nosmai processing to track $videoTrackId',
    );
    try {
      await _channel.invokeMethod('attachNosmaiProcessing', {
        'videoTrackId': videoTrackId,
        'isFrontCamera': isFrontCamera,
      });
      developer.log('[NosmaiLiveKitBridge] Nosmai processing attached');
    } catch (e, s) {
      developer.log(
        '[NosmaiLiveKitBridge] attachNosmaiProcessing failed',
        error: e,
        stackTrace: s,
      );
      rethrow;
    }
  }

  /// Updates the camera facing direction so Nosmai applies the correct
  /// mirroring/orientation for the active camera.
  ///
  /// Call this after switching the camera (e.g. `track.setCameraPosition(...)`).
  /// On most setups you should re-call [attachNosmaiProcessing] after a switch,
  /// but this is provided for finer control.
  static Future<void> updateNosmaiCameraFacing({
    required bool isFrontCamera,
  }) async {
    try {
      await _channel.invokeMethod('updateNosmaiCameraFacing', {
        'isFrontCamera': isFrontCamera,
      });
    } catch (e, s) {
      developer.log(
        '[NosmaiLiveKitBridge] updateNosmaiCameraFacing failed',
        error: e,
        stackTrace: s,
      );
      rethrow;
    }
  }

  /// Removes the Nosmai processor from the track and releases its resources.
  ///
  /// Call this when streaming ends, before disposing the track / leaving the
  /// screen.
  static Future<void> releaseNosmaiProcessing() async {
    developer.log('[NosmaiLiveKitBridge] Releasing Nosmai processing...');
    try {
      await _channel.invokeMethod('releaseNosmaiProcessing');
      developer.log('[NosmaiLiveKitBridge] Nosmai processing released');
    } catch (e, s) {
      developer.log(
        '[NosmaiLiveKitBridge] releaseNosmaiProcessing failed',
        error: e,
        stackTrace: s,
      );
      rethrow;
    }
  }

  /// Returns the host platform version. Useful as a connectivity sanity check.
  static Future<String?> getPlatformVersion() async {
    try {
      return await _channel.invokeMethod<String>('getPlatformVersion');
    } catch (e) {
      developer.log('[NosmaiLiveKitBridge] getPlatformVersion failed', error: e);
      return null;
    }
  }
}
