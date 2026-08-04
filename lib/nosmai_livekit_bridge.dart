import 'dart:developer' as developer;

import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
// MediaStreamTrackNative is not exported from flutter_webrtc.dart — wrapping a
// natively-minted track id has no supported public constructor, so the
// implementation path is imported deliberately. Kept HERE rather than in app
// code: this is plugin plumbing, and no consumer should have to know it.
// ignore: implementation_imports
import 'package:flutter_webrtc/src/native/media_stream_track_impl.dart'
    show MediaStreamTrackNative;
import 'package:livekit_client/livekit_client.dart';

/// Nosmai ↔ LiveKit bridge.
///
/// Publishes Nosmai's filtered camera output to a LiveKit room as a GPU texture
/// — one blit per frame, no readback, no colour conversion.
///
/// ## The model
///
/// **Nosmai owns the camera and the preview. LiveKit only publishes.**
///
/// Your app must mount a `NosmaiCameraPreview` and must NOT create a LiveKit
/// camera track. This is not a stylistic preference:
///
/// * `NosmaiCameraPreview` is what creates the platform view Nosmai's
///   `startProcessing()` waits for. Without it, `startProcessing()` silently
///   defers and no frames are ever produced.
/// * Mounting it is also what sets the SDK's current GL view, without which
///   `applyFilter` fails with "Cannot apply filter: GL preview is unavailable".
///   Unmounting it clears that again, so it must stay mounted for the session.
/// * Calling `LocalVideoTrack.createCameraTrack()` opens a SECOND camera and,
///   historically, a second Nosmai pipeline contending for the one GL worker —
///   measured at roughly a third of the achievable frame rate.
///
/// ## Usage
///
/// ```dart
/// // 1. BEFORE Nosmai initializes — joins flutter_webrtc's EGL share group.
/// await NosmaiLiveKitBridge.registerShareContext();
/// await NosmaiFlutter.initialize(licenseKey);
///
/// // 2. Mount NosmaiCameraPreview in your widget tree. It owns the screen.
/// //    (Nosmai's own startProcessing is driven by the widget.)
///
/// // 3. Publish. The bridge mints the track; you publish it as usual.
/// final track = await NosmaiLiveKitBridge.createVideoTrack();
/// final room = Room();
/// await room.connect(url, token);
/// await room.localParticipant!.publishVideoTrack(track);
///
/// // 4. Camera switching goes through Nosmai, never LiveKit.
/// await NosmaiFlutter.instance.switchCamera();
///
/// // 5. Teardown.
/// await NosmaiLiveKitBridge.stopStreaming();
/// await room.disconnect();
/// ```
class NosmaiLiveKitBridge {
  NosmaiLiveKitBridge._();

  static const MethodChannel _channel = MethodChannel('nosmai_livekit_bridge');

  /// Joins flutter_webrtc's EGL share group so Nosmai's output textures are
  /// usable by the WebRTC encoder.
  ///
  /// **MUST be awaited before `NosmaiFlutter.initialize()`.** The share handle
  /// is consumed when Nosmai's GL context is constructed; a later call is
  /// ignored, Nosmai gets a standalone context, and the remote shows black with
  /// no error anywhere. Returns the native EGL handle, or null on failure.
  ///
  /// Idempotent — safe to call more than once.
  static Future<int?> registerShareContext() async {
    try {
      return await _channel.invokeMethod<int>('registerShareContext');
    } catch (e, s) {
      developer.log('[NosmaiLiveKitBridge] registerShareContext failed',
          error: e, stackTrace: s);
      return null;
    }
  }

  /// Creates a [LocalVideoTrack] carrying Nosmai's filtered camera output,
  /// ready to hand to `publishVideoTrack`.
  ///
  /// This is the method to use. It mints the native track, wraps it in LiveKit's
  /// Dart types, and hides the plumbing that would otherwise leak into app code
  /// (the lazily-created `PeerConnectionFactory`, and the fact that
  /// `MediaStreamTrackNative` is not part of flutter_webrtc's public API).
  ///
  /// Requires the Nosmai camera to be running — i.e. a `NosmaiCameraPreview`
  /// mounted in the widget tree. Throws [StateError] if the native side cannot
  /// start; the message says why.
  ///
  /// ```dart
  /// final track = await NosmaiLiveKitBridge.createVideoTrack();
  /// await room.localParticipant!.publishVideoTrack(track);
  /// ```
  static Future<LocalVideoTrack> createVideoTrack() async {
    // flutter_webrtc builds its PeerConnectionFactory lazily, on its first
    // "initialize" method call. On a cold start it is null and the native mint
    // fails, so provoke it with a throwaway stream first.
    final warmup = await rtc.createLocalMediaStream('nosmai-warmup');
    await warmup.dispose();

    final r = await startStreaming();
    if (r == null) {
      throw StateError(
          'Nosmai LiveKit bridge failed to start. Check that the Nosmai camera '
          'is running (is NosmaiCameraPreview mounted?) and see the native log.');
    }

    final nativeTrack =
        MediaStreamTrackNative(r['trackId']!, r['label']!, 'video', true, '');
    final stream = await rtc.createLocalMediaStream(r['label']!);
    // LocalVideoTrack's constructor is marked @internal — an analyzer lint, not
    // a runtime restriction. Publishing an externally-sourced track has no
    // supported alternative in livekit_client 2.10.0.
    // ignore: invalid_use_of_internal_member
    return LocalVideoTrack(
      TrackSource.camera,
      stream,
      nativeTrack,
      const CameraCaptureOptions(),
    );
  }

  /// Lower-level: mints the native track and returns `{trackId, label}` without
  /// wrapping it. Prefer [createVideoTrack] unless you need the raw id.
  static Future<Map<String, String>?> startStreaming() async {
    final r =
        await _channel.invokeMethod<Map<dynamic, dynamic>>('startStreaming');
    if (r == null) return null;
    return r.map((k, v) => MapEntry(k.toString(), v.toString()));
  }

  /// Stops streaming and releases the track and its GL resources.
  ///
  /// Safe to call when not streaming. Call this BEFORE disconnecting the room.
  static Future<void> stopStreaming() async {
    try {
      await _channel.invokeMethod('stopStreaming');
    } catch (e) {
      developer.log('[NosmaiLiveKitBridge] stopStreaming failed', error: e);
    }
  }

  static Future<bool> isStreaming() async {
    try {
      return await _channel.invokeMethod<bool>('isStreaming') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Rotation stamped on outgoing frames (0/90/180/270).
  ///
  /// WebRTC carries this as metadata and the receiver applies it, so changing it
  /// costs the sender nothing and takes effect on the next frame — no restart,
  /// no re-publish.
  ///
  /// Defaults to 0, and 0 is correct on Android: Nosmai's streaming pass already
  /// delivers upright portrait frames, so any non-zero value here ADDS a
  /// rotation rather than correcting one. Exposed for unusual sources and for
  /// diagnosing orientation on a remote viewer.
  static Future<void> setRotation(int degrees) async {
    try {
      await _channel.invokeMethod('setRotation', {'degrees': degrees});
    } catch (e) {
      developer.log('[NosmaiLiveKitBridge] setRotation failed', error: e);
    }
  }

  /// Host platform version. Useful as a channel sanity check.
  static Future<String?> getPlatformVersion() async {
    try {
      return await _channel.invokeMethod<String>('getPlatformVersion');
    } catch (e) {
      developer.log('[NosmaiLiveKitBridge] getPlatformVersion failed', error: e);
      return null;
    }
  }
}
