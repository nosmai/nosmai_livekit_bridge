## 0.0.1

* Initial release.
* `attachNosmaiProcessing` / `updateNosmaiCameraFacing` / `releaseNosmaiProcessing` to add
  real-time Nosmai filters to a LiveKit camera track via a native frame processor.
* Android: `LocalVideoTrack.ExternalVideoFrameProcessing` (I420), grey/OOM/camera-switch fixes.
* iOS: `ExternalVideoProcessingDelegate` (CVPixelBuffer in-place) — experimental.
