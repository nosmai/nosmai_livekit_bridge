## 0.1.0

Rewritten around a different architecture. **Breaking**: the 0.0.1 API is gone.

* **Nosmai now owns the camera and preview; LiveKit only publishes.** The previous model —
  attaching a frame processor to a LiveKit camera track and filtering in place — could never
  support AR effects, beauty or background segmentation: the SDK's external frame pipeline is
  a single-filter graph with no face detection, landmarks or segmentation. It also ran two
  camera captures and two Nosmai pipelines against one GL worker, costing roughly two thirds
  of the achievable frame rate.
* **Zero-copy on both platforms.** Android blits Nosmai's output texture once inside
  flutter_webrtc's EGL share group; iOS passes IOSurface-backed `CVPixelBuffer`s straight
  through. No readbacks, no colour conversion, no per-frame CPU copies.
* Measured ~30 fps at 720×1280 with AR effects active — Pixel 5 and iPhone 15.
* New API: `registerShareContext`, `createVideoTrack`, `startStreaming`, `stopStreaming`,
  `isStreaming`, `setRotation`. Removed: `attachNosmaiProcessing`,
  `updateNosmaiCameraFacing`, `releaseNosmaiProcessing`.
* `createVideoTrack()` returns a ready-to-publish `LocalVideoTrack`, keeping the track-wrapping
  plumbing inside the plugin rather than in application code.
* iOS minimum deployment target raised to 15.0 (required by `nosmai_camera_sdk`).
* Added a standalone browser viewer under `tools/livekit-viewer/` that renders the published
  stream without cropping and reports live resolution, orientation, fps and codec.

## 0.0.1

* Initial release.
* `attachNosmaiProcessing` / `updateNosmaiCameraFacing` / `releaseNosmaiProcessing` to add
  real-time Nosmai filters to a LiveKit camera track via a native frame processor.
* Android: `LocalVideoTrack.ExternalVideoFrameProcessing` (I420), grey/OOM/camera-switch fixes.
* iOS: `ExternalVideoProcessingDelegate` (CVPixelBuffer in-place) — experimental.
