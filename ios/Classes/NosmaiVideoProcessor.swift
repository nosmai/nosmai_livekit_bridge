import Foundation
import AVFoundation

/// Nosmai video processor for iOS - implements flutter_webrtc's ExternalVideoProcessingDelegate.
/// This is the iOS equivalent of Android's ExternalVideoFrameProcessing pattern.
///
/// Frame flow: flutter_webrtc camera capture -> NosmaiVideoProcessor.onFrame() -> Nosmai SDK -> encoder
///
/// Processing pipeline for NV12 frames (common on iOS):
/// 1. Extract CVPixelBuffer from RTCVideoFrame
/// 2. Convert NV12 → BGRA (Nosmai expects BGRA)
/// 3. Process BGRA buffer with Nosmai SDK
/// 4. Convert BGRA → NV12 (write back to original buffer)
/// 5. Return original frame (now containing processed data)
///
/// Note: We reach RTCVideoFrame properties through the RTCFrameHelper Objective-C helper because
/// importing WebRTC directly into Swift can conflict with other WebRTC builds on the classpath.
@objc public class NosmaiVideoProcessor: NSObject {

    /// Current camera facing direction.
    @objc public var isFrontCamera: Bool = true

    /// Whether the Nosmai pipeline is ready.
    private var pipelineReady: Bool = false

    /// Frame count for the warmup period.
    private var frameCount: Int = 0

    /// Number of warmup frames to skip before processing (lets the camera settle).
    private let warmupFrames: Int = 12

    /// Lock for thread safety.
    private let lock = NSLock()

    /// Track if we've logged the first successful processing (reduce log spam).
    private var hasLoggedFirstProcess: Bool = false

    @objc public init(isFrontCamera: Bool) {
        self.isFrontCamera = isFrontCamera
        super.init()
        print("[NosmaiVideoProcessor] Initialized with isFrontCamera: \(isFrontCamera)")
    }

    /// Updates the camera facing direction and resets the pipeline.
    @objc public func updateCameraFacing(_ isFront: Bool) {
        lock.lock()
        defer { lock.unlock() }

        isFrontCamera = isFront
        pipelineReady = false
        frameCount = 0
        hasLoggedFirstProcess = false
        print("[NosmaiVideoProcessor] Camera facing updated to: \(isFront ? "front" : "back")")
    }

    /// Releases the processor and cleans up resources.
    /// Named releaseProcessor instead of release to avoid ARC conflicts.
    @objc public func releaseProcessor() {
        lock.lock()
        defer { lock.unlock() }

        pipelineReady = false
        frameCount = 0
        hasLoggedFirstProcess = false

        // Clean up cached buffers in RTCFrameHelper.
        RTCFrameHelper.cleanup()

        print("[NosmaiVideoProcessor] Released")
    }

    /// Called by flutter_webrtc for each video frame.
    /// Implements the ExternalVideoProcessingDelegate protocol.
    /// - Parameter frame: The RTCVideoFrame to process (typed as AnyObject to avoid module conflicts).
    /// - Returns: The processed RTCVideoFrame (same object, modified in place).
    @objc public func onFrame(_ frame: AnyObject) -> AnyObject {
        lock.lock()
        defer { lock.unlock() }

        // Warmup: pass first frames through unprocessed (lets camera exposure settle).
        if !pipelineReady && frameCount < warmupFrames {
            frameCount += 1
            return frame
        }

        // Get the original NV12 pixel buffer from the frame.
        guard let originalPixelBuffer = extractOriginalPixelBuffer(from: frame) else {
            // Frame doesn't carry a CVPixelBuffer (might be I420) - pass through unprocessed.
            return frame
        }

        // Check if this is NV12 format that needs conversion.
        let isNV12 = RTCFrameHelper.isNV12Format(originalPixelBuffer)

        // Get the BGRA pixel buffer (converted if needed) for Nosmai processing.
        guard let bgraPixelBuffer = RTCFrameHelper.pixelBuffer(fromFrame: frame) else {
            // Conversion failed - pass through unprocessed.
            return frame
        }

        // Initialize the pipeline on the first processed frame.
        if !pipelineReady {
            let width = CVPixelBufferGetWidth(bgraPixelBuffer)
            let height = CVPixelBufferGetHeight(bgraPixelBuffer)
            pipelineReady = initializePipeline(width: width, height: height)
            if !pipelineReady {
                print("[NosmaiVideoProcessor] Pipeline initialization failed, passing frame through")
                return frame
            }
        }

        // Lock the BGRA buffer for Nosmai processing.
        let lockFlags = CVPixelBufferLockFlags(rawValue: 0)
        guard CVPixelBufferLockBaseAddress(bgraPixelBuffer, lockFlags) == kCVReturnSuccess else {
            print("[NosmaiVideoProcessor] Failed to lock BGRA pixel buffer")
            return frame
        }

        // Process with the Nosmai SDK (in-place modification of BGRA buffer).
        // Always tell Nosmai "back camera" (false) per the Android pattern: Nosmai's
        // front-camera in-place flip corrupts data. Mirror is handled by the renderer.
        let processed = NosmaiProcessor.process(bgraPixelBuffer, shouldFlip: false)

        CVPixelBufferUnlockBaseAddress(bgraPixelBuffer, lockFlags)

        if !processed {
            // Nosmai SDK not available or processing failed.
            return frame
        }

        // If the original was NV12, we need to copy the processed BGRA back to NV12.
        if isNV12 {
            let copySuccess = RTCFrameHelper.copyBGRA(toNV12: bgraPixelBuffer, dest: originalPixelBuffer)
            if !copySuccess {
                print("[NosmaiVideoProcessor] Failed to copy processed BGRA back to NV12")
                return frame
            }
        }

        if !hasLoggedFirstProcess {
            let width = CVPixelBufferGetWidth(bgraPixelBuffer)
            let height = CVPixelBufferGetHeight(bgraPixelBuffer)
            print("[NosmaiVideoProcessor] First frame processed successfully: \(width)x\(height), isNV12: \(isNV12)")
            hasLoggedFirstProcess = true
        }

        // Return the same frame object - the pixel buffer was modified in place.
        return frame
    }

    /// Extract the original CVPixelBuffer from RTCVideoFrame (without conversion).
    private func extractOriginalPixelBuffer(from frame: AnyObject) -> CVPixelBuffer? {
        // Use the Objective-C helper to avoid KVC issues with RTCCVPixelBuffer.
        // RTCFrameHelper can directly access the pixelBuffer property.
        return RTCFrameHelper.originalPixelBuffer(fromFrame: frame)
    }

    /// Initialize the Nosmai processing pipeline.
    private func initializePipeline(width: Int, height: Int) -> Bool {
        guard let cls = NSClassFromString("NosmaiFlutterPlugin") as? NSObject.Type else {
            print("[NosmaiVideoProcessor] NosmaiFlutterPlugin class not found - Nosmai SDK not loaded")
            return false  // Cannot process without Nosmai SDK.
        }

        let setModeSelector = NSSelectorFromString("setExternalFrameMode:")
        if cls.responds(to: setModeSelector) {
            let method = class_getClassMethod(cls, setModeSelector)
            typealias SetModeFunc = @convention(c) (AnyClass, Selector, Bool) -> Void
            let implementation = method_getImplementation(method!)
            let setModeFunc = unsafeBitCast(implementation, to: SetModeFunc.self)
            setModeFunc(cls, setModeSelector, true)
            print("[NosmaiVideoProcessor] External frame mode enabled")
        }

        print("[NosmaiVideoProcessor] Pipeline initialized: \(width)x\(height)")
        return true
    }
}
