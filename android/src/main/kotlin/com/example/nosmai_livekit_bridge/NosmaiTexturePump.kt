package com.example.nosmai_livekit_bridge

import android.util.Log
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import com.cloudwebrtc.webrtc.utils.EglUtils
import com.nosmai.effect.api.NosmaiSDK
import org.webrtc.CapturerObserver
import org.webrtc.SurfaceTextureHelper
import org.webrtc.VideoSource
import org.webrtc.VideoTrack
import org.webrtc.YuvConverter
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Publishes Nosmai's filtered output to a WebRTC track as a GPU texture.
 *
 * MODEL (mirrors the working Agora bridge): Nosmai owns the camera AND the
 * on-screen preview; LiveKit only encodes and transports. LiveKit must NEVER
 * capture — a second capture path means a second Nosmai pipeline contending for
 * the one GL worker, which measured a ~2.4x fps loss before this rebuild.
 *
 * Per frame: ONE glBlitFramebuffer. No readback, no I420 convert, no CPU copies.
 */
object NosmaiTexturePump {
    private const val TAG = "NosmaiTexturePump"

    // Share-context registration is process-wide and one-shot: the handle is
    // consumed when NosmaiContext is constructed, and a later call is rejected
    // (nosmai_context.cc:114-121 logs "called AFTER context creation" and
    // returns). Latching avoids a confusing second attempt.
    private var shareCtxRegistered = false
    private var cachedHandle: Long = 0

    private var source: VideoSource? = null
    private var track: VideoTrack? = null
    private var observer: CapturerObserver? = null
    private var helper: SurfaceTextureHelper? = null
    private var yuvConverter: YuvConverter? = null
    private var bridge: NosmaiTextureBridge? = null

    @Volatile private var streaming = false

    val isStreaming: Boolean get() = streaming

    /** Rotation stamped on outgoing frames; see NosmaiTextureBridge. 0 is correct. */
    var rotationDegrees: Int = 0
        set(v) { field = v; bridge?.rotationDegrees = v }

    /**
     * Join flutter_webrtc's EGL share group. MUST be called BEFORE Nosmai's GL
     * context exists (i.e. before NosmaiFlutter.initialize), otherwise Nosmai
     * gets a standalone context, its texture ids are meaningless to the encoder,
     * and the remote goes black with NO error surfaced anywhere.
     *
     * Verify success in logcat: "Creating GL context in a SHARED group"
     * (nosmai_context.cc:309, internal-logs builds only).
     */
    fun registerShareContext(): Long? {
        if (shareCtxRegistered) return cachedHandle
        return try {
            // Force the native library up first; setAgoraShareContext is a
            // native method and would otherwise throw UnsatisfiedLinkError,
            // silently costing the share group. Mirrors the Agora bridge.
            System.loadLibrary("nosmai")
            val ctx = EglUtils.getRootEglBaseContext()
                ?: run { Log.e(TAG, "root EglBase context is null"); return null }
            val handle = ctx.nativeEglContext
            // Name is Agora-historical; the native side is generic — it is just
            // the share argument to eglCreateContext (nosmai_context.cc:307-314).
            NosmaiSDK.setAgoraShareContext(handle)
            shareCtxRegistered = true
            cachedHandle = handle
            Log.i(TAG, "✅ EGL share context registered handle=$handle")
            handle
        } catch (t: Throwable) {
            Log.e(TAG, "registerShareContext failed: ${t.message}", t)
            null
        }
    }

    /**
     * Mint a WebRTC track, register it with flutter_webrtc, and arm Nosmai's
     * texture output to feed it. Returns the track id for the Dart side to wrap.
     */
    fun startStreaming(): String? {
        if (streaming) {
            Log.w(TAG, "startStreaming called while already streaming; stopping first")
            stopStreaming()
        }
        try {
            val plugin = FlutterWebRTCPlugin.sharedSingleton
                ?: run { Log.e(TAG, "FlutterWebRTCPlugin.sharedSingleton is null"); return null }
            // Created lazily by flutter_webrtc's "initialize" method call, so the
            // Dart side must have made some WebRTC call before this runs.
            val factory = plugin.peerConnectionFactory
                ?: run { Log.e(TAG, "peerConnectionFactory is null (WebRTC not initialized)"); return null }
            val rootCtx = EglUtils.getRootEglBaseContext()
                ?: run { Log.e(TAG, "root EglBase context is null"); return null }

            val src = factory.createVideoSource(false)
            val id = "nosmai-" + UUID.randomUUID().toString()
            val vt = factory.createVideoTrack(id, src)

            // flutter_webrtc resolves trackId against MethodCallHandlerImpl's
            // registry, but exposes no getter for it (FlutterWebRTCPlugin.java:44
            // is private). Reflect the FIELD only, then call putLocalTrack — a
            // normal method on the PUBLIC StateProvider interface
            // (StateProvider.java:23, implemented at MethodCallHandlerImpl.java:107).
            val f = FlutterWebRTCPlugin::class.java.getDeclaredField("methodCallHandler")
            f.isAccessible = true
            val handler = f.get(plugin)
                ?: run { Log.e(TAG, "methodCallHandler is null"); return null }
            (handler as com.cloudwebrtc.webrtc.StateProvider)
                .putLocalTrack(id, com.cloudwebrtc.webrtc.video.LocalVideoTrack(vt))

            val obs = src.capturerObserver
            // Load-bearing: without this every frame is dropped silently, which
            // is indistinguishable from "the track never published".
            obs.onCapturerStarted(true)

            // PER-STREAM, never at plugin init. A helper kept alive across
            // stop/start keeps its GL thread contending for the single Nosmai
            // worker after streaming ended — the documented cause of the
            // "second go-live freezes" bug in the Agora bridge.
            val sth = SurfaceTextureHelper.create("NosmaiLK", rootCtx)
                ?: run { Log.e(TAG, "SurfaceTextureHelper.create returned null"); return null }

            // YuvConverter allocates GL objects, so it must be constructed ON
            // the helper's GL thread. SurfaceTextureHelper exposes no getter for
            // its own, so we build one and hand it to the TextureBufferImpl
            // (which needs it only if something later calls toI420()).
            var conv: YuvConverter? = null
            val latch = CountDownLatch(1)
            sth.handler.post {
                try { conv = YuvConverter() } catch (t: Throwable) {
                    Log.e(TAG, "YuvConverter init failed", t)
                } finally { latch.countDown() }
            }
            latch.await(2, TimeUnit.SECONDS)
            val yc = conv ?: run {
                Log.e(TAG, "YuvConverter unavailable")
                sth.dispose()
                return null
            }

            val br = NosmaiTextureBridge(sth, obs, yc)
            br.rotationDegrees = rotationDegrees

            source = src; track = vt; observer = obs
            helper = sth; yuvConverter = yc; bridge = br
            streaming = true

            // TWO INDEPENDENT NATIVE GATES. Arming only one produces ZERO frames
            // with no error:
            //   1) render mode must permit a streaming pass
            //      (ShouldRenderStreaming, sink_raw_data.cc:564)
            //   2) the texture callback must be registered, which sets
            //      stream_texture_mode_ (sink_raw_data.cc:624)
            // DUAL_OUTPUT (not STREAMING_ONLY) because Nosmai owns the VISIBLE
            // preview in this model — STREAMING_ONLY would blank it.
            NosmaiSDK.setRenderMode(NosmaiSDK.RenderMode.DUAL_OUTPUT)
            NosmaiSDK.setTextureFrameCallback { texId, w, h, tsNs, _ ->
                // Runs on the Nosmai GL worker. Must never block: hand off and
                // return. releaseStreamSlot is lock-free and needs no GL context
                // (jni_nosmai.cc:559-566), so it is safe from any thread — but it
                // MUST run exactly once per frame or the producer ring starves
                // and the stream freezes silently.
                if (!streaming) {
                    NosmaiSDK.releaseStreamSlot(texId)
                } else {
                    br.pushCopy(texId, w, h, tsNs) { NosmaiSDK.releaseStreamSlot(texId) }
                }
            }

            Log.i(TAG, "✅ streaming: track $id armed (rotation=$rotationDegrees)")
            return id
        } catch (t: Throwable) {
            Log.e(TAG, "startStreaming failed: ${t.javaClass.simpleName}: ${t.message}", t)
            stopStreaming()
            return null
        }
    }

    /**
     * Teardown order is load-bearing: stop PRODUCING before tearing down the
     * consumer, and drop the render mode back before releasing the helper, so
     * the Nosmai worker is uncontended when the helper's GL thread joins.
     */
    fun stopStreaming() {
        streaming = false
        try { NosmaiSDK.setTextureFrameCallback(null) } catch (_: Throwable) {}
        try { NosmaiSDK.setRenderMode(NosmaiSDK.RenderMode.PREVIEW_ONLY) } catch (_: Throwable) {}
        try { bridge?.release() } catch (_: Throwable) {}
        try { observer?.onCapturerStopped() } catch (_: Throwable) {}
        try { yuvConverter?.let { c -> helper?.handler?.post { c.release() } } } catch (_: Throwable) {}
        try { helper?.dispose() } catch (_: Throwable) {}
        try { track?.dispose() } catch (_: Throwable) {}
        try { source?.dispose() } catch (_: Throwable) {}
        bridge = null; helper = null; yuvConverter = null
        observer = null; track = null; source = null
        Log.i(TAG, "stopped")
    }
}
