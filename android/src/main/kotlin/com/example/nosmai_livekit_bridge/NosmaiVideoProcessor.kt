package com.example.nosmai_livekit_bridge

import com.cloudwebrtc.webrtc.video.LocalVideoTrack
import org.webrtc.VideoFrame
import java.nio.ByteBuffer

class NosmaiVideoProcessor(
    @Volatile private var isFrontCamera: Boolean
) : LocalVideoTrack.ExternalVideoFrameProcessing {

    @Volatile private var pipelineReady = false

    // Frames seen since (re)attach. The camera's SurfaceTexture transform and auto-exposure are
    // not settled on the first frames, so toI420() during this window yields a non-rotated
    // (landscape), chroma-incomplete (grey) buffer. We pass those frames through untouched and
    // only initialise the Nosmai pipeline once the camera has stabilised.
    @Volatile private var frameCount = 0
    private val warmupFrames = 12

    // The VideoFrame we allocated and returned on the PREVIOUS call. flutter_webrtc's
    // onFrameCaptured releases the frame it passes IN, never the frame we return, so we
    // own this reference and must release it ourselves. We defer that release by one frame:
    // by the time the next frame arrives, sink.onFrame() has already run synchronously and
    // the encoder/renderer have retained whatever they needed. Without this, every frame
    // leaks a full I420 buffer (~1.3 MB at 720p) -> OOM crash within a minute of streaming.
    private val frameLock = Any()
    private var lastProcessedFrame: VideoFrame? = null

    override fun onFrame(videoFrame: VideoFrame): VideoFrame {
        // Release the frame allocated on the previous call (sink has consumed it by now).
        synchronized(frameLock) {
            lastProcessedFrame?.release()
            lastProcessedFrame = null
        }

        // Warm-up: pass the first frames straight through (the renderer applies the camera's
        // texture transform itself, so passthrough frames display correctly). This avoids the
        // landscape/grey artifact from toI420() before the camera's transform/exposure settle.
        if (!pipelineReady && frameCount < warmupFrames) {
            frameCount++
            return videoFrame
        }

        // toI420() converts the texture to I420, baking in the camera's mirror but NOT the 90deg
        // rotation (that lives in videoFrame.rotation). So the buffer is in the sensor's
        // landscape orientation and we carry videoFrame.rotation through to the output below.
        // We must NOT release `videoFrame` (the input) -- flutter_webrtc's caller owns it.
        val srcRotation = videoFrame.rotation
        val i420 = videoFrame.buffer.toI420() ?: return videoFrame

        if (!pipelineReady) {
            val ok = NosmaiReflection.initializeExternalFramePipeline(i420.width, i420.height)
            if (ok) {
                NosmaiReflection.setExternalFrameMode(true)
                // ALWAYS tell Nosmai "back camera" (false). Telling it "front" makes it do an
                // in-place horizontal flip of the I420 whose UV-plane handling is buggy -- that
                // is what produced the grey + flipped image on the front camera. Any selfie
                // mirror for local preview is handled cosmetically by the renderer's mirrorMode.
                NosmaiReflection.setCameraFacing(false)
                NosmaiReflection.setMirrorX(false)
                pipelineReady = true
                println(
                    "[NosmaiProcessor] pipeline init ok=$ok ready=" +
                        "${NosmaiReflection.isExternalFramePipelineReady()} " +
                        "dims=${i420.width}x${i420.height} srcRotation=$srcRotation front=$isFrontCamera"
                )
            } else {
                println("[NosmaiProcessor] initializeExternalFramePipeline FAILED -- frame passed through unprocessed")
                i420.release()
                return videoFrame
            }
        }

        // flutter_webrtc's toI420() returns Y/U/V as slices of ONE backing buffer with padded
        // per-plane strides. Nosmai's native processExternalI420InPlace mis-reads chroma from
        // such slices/strides (-> grey, regardless of rotation/facing). So we hand it three
        // STANDALONE, TIGHTLY-PACKED plane buffers, then copy the processed result back into the
        // WebRTC i420 (whose buffer management we reuse for clean output + release).
        val w = i420.width
        val h = i420.height
        val cw = (w + 1) / 2   // chroma width
        val ch = (h + 1) / 2   // chroma height

        val packedY = packPlane(i420.dataY, i420.strideY, w, h)
        val packedU = packPlane(i420.dataU, i420.strideU, cw, ch)
        val packedV = packPlane(i420.dataV, i420.strideV, cw, ch)

        // rotation=0, isFront=false: Nosmai must not rotate/flip in-place; orientation is carried
        // by the output VideoFrame's rotation metadata below.
        NosmaiReflection.processExternalI420InPlace(
            packedY, packedU, packedV,
            w, h,
            w, cw, cw,   // tight strides
            0, false
        )

        // Copy the processed (packed) planes back into the WebRTC i420's strided planes.
        unpackPlane(packedY, i420.dataY, i420.strideY, w, h)
        unpackPlane(packedU, i420.dataU, i420.strideU, cw, ch)
        unpackPlane(packedV, i420.dataV, i420.strideV, cw, ch)

        // Carry the source rotation so the renderer/encoder rotate the landscape buffer upright.
        // We own this i420 reference (from toI420); track it for deferred release.
        val out = VideoFrame(i420, srcRotation, videoFrame.timestampNs)
        synchronized(frameLock) {
            lastProcessedFrame = out
        }
        return out
    }

    fun updateCameraFacing(isFront: Boolean) {
        isFrontCamera = isFront
        // Reset so the pipeline re-initialises on the next frame with the new camera's
        // dimensions, and re-run warm-up so the new camera's texture transform settles before
        // toI420()/Nosmai run. We deliberately do NOT call setCameraFacing(true) for the front
        // camera -- Nosmai's front-camera in-place flip corrupts the I420 (grey). It is always
        // treated as "back" (false) and re-applied at pipeline init.
        pipelineReady = false
        frameCount = 0
        NosmaiReflection.setCameraFacing(false)
    }

    fun release() {
        if (pipelineReady) {
            NosmaiReflection.setExternalFrameMode(false)
            pipelineReady = false
        }
        synchronized(frameLock) {
            lastProcessedFrame?.release()
            lastProcessedFrame = null
        }
    }

    /**
     * Copies a strided plane (a slice of WebRTC's I420 backing buffer) into a fresh, standalone,
     * tightly-packed direct ByteBuffer (stride == width). This gives Nosmai's native code a plane
     * whose base address is exactly the plane data, sidestepping slice-offset / padded-stride
     * mis-reads that corrupt chroma.
     */
    private fun packPlane(srcOrig: ByteBuffer, srcStride: Int, width: Int, height: Int): ByteBuffer {
        val src = srcOrig.duplicate()
        val dst = ByteBuffer.allocateDirect(width * height)
        val row = ByteArray(width)
        for (y in 0 until height) {
            src.position(y * srcStride)
            src.get(row, 0, width)
            dst.put(row)
        }
        dst.position(0)
        return dst
    }

    /** Copies a tightly-packed plane back into a strided WebRTC plane buffer. */
    private fun unpackPlane(srcPacked: ByteBuffer, dstOrig: ByteBuffer, dstStride: Int, width: Int, height: Int) {
        val src = srcPacked.duplicate()
        src.position(0)
        val dst = dstOrig.duplicate()
        val row = ByteArray(width)
        for (y in 0 until height) {
            src.get(row, 0, width)
            dst.position(y * dstStride)
            dst.put(row)
        }
    }
}
