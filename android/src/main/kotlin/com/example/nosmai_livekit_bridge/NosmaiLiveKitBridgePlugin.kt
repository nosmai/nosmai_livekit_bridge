package com.example.nosmai_livekit_bridge

import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

class NosmaiLiveKitBridgePlugin : FlutterPlugin, MethodCallHandler {

    private lateinit var channel: MethodChannel
    private var nosmaiProcessor: NosmaiVideoProcessor? = null

    // Keep a reference to the track we attached to, so we can detach the processor on
    // release. Leaving a dead processor in the track's list keeps it receiving frames
    // (and re-initialising the Nosmai pipeline) until the track itself stops.
    private var attachedTrack: com.cloudwebrtc.webrtc.video.LocalVideoTrack? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "nosmai_livekit_bridge")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {

            "attachNosmaiProcessing" -> {
                val trackId = call.argument<String>("videoTrackId")
                val isFrontCamera = call.argument<Boolean>("isFrontCamera") ?: true

                if (trackId == null) {
                    result.error("INVALID_ARGS", "videoTrackId is required", null)
                    return
                }

                try {
                    val plugin = FlutterWebRTCPlugin.sharedSingleton
                        ?: throw IllegalStateException("FlutterWebRTCPlugin not initialized")

                    val localTrack = plugin.getLocalTrack(trackId)
                        ?: throw IllegalStateException("Track '$trackId' not found in flutter_webrtc registry")

                    if (localTrack !is com.cloudwebrtc.webrtc.video.LocalVideoTrack) {
                        throw IllegalStateException(
                            "Expected LocalVideoTrack, got ${localTrack::class.java.simpleName}"
                        )
                    }

                    // Detach any previous processor before attaching a new one.
                    nosmaiProcessor?.let { attachedTrack?.removeProcessor(it) }
                    nosmaiProcessor?.release()

                    val processor = NosmaiVideoProcessor(isFrontCamera)
                    nosmaiProcessor = processor
                    attachedTrack = localTrack
                    localTrack.addProcessor(processor)
                    println("[NosmaiPlugin] Nosmai processor attached to track $trackId")
                    result.success(null)
                } catch (e: Exception) {
                    println("[NosmaiPlugin] attachNosmaiProcessing failed: ${e.message}")
                    result.error("ATTACH_ERROR", e.message, null)
                }
            }

            "updateNosmaiCameraFacing" -> {
                val isFrontCamera = call.argument<Boolean>("isFrontCamera") ?: true
                nosmaiProcessor?.updateCameraFacing(isFrontCamera)
                result.success(null)
            }

            "releaseNosmaiProcessing" -> {
                nosmaiProcessor?.let { attachedTrack?.removeProcessor(it) }
                nosmaiProcessor?.release()
                nosmaiProcessor = null
                attachedTrack = null
                result.success(null)
            }

            "getPlatformVersion" -> result.success("Android ${android.os.Build.VERSION.RELEASE}")

            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        nosmaiProcessor?.let { attachedTrack?.removeProcessor(it) }
        nosmaiProcessor?.release()
        nosmaiProcessor = null
        attachedTrack = null
    }
}
