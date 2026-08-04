package com.example.nosmai_livekit_bridge

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/**
 * Nosmai ↔ LiveKit bridge.
 *
 * Nosmai owns the camera and the on-screen preview; this plugin only exposes
 * Nosmai's already-filtered output to LiveKit as a WebRTC video track. It never
 * captures, and it never touches LiveKit's Room/Participant APIs — the host app
 * keeps full control of those.
 */
class NosmaiLiveKitBridgePlugin : FlutterPlugin, MethodCallHandler {

    private lateinit var channel: MethodChannel

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "nosmai_livekit_bridge")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {

            "registerShareContext" -> {
                val handle = NosmaiTexturePump.registerShareContext()
                if (handle == null) {
                    result.error("SHARE_CTX", "see logcat NosmaiTexturePump", null)
                } else {
                    result.success(handle)
                }
            }

            "startStreaming" -> {
                val id = NosmaiTexturePump.startStreaming()
                if (id == null) {
                    result.error("START_FAILED", "see logcat NosmaiTexturePump", null)
                } else {
                    result.success(mapOf("trackId" to id, "label" to "nosmai"))
                }
            }

            "stopStreaming" -> {
                NosmaiTexturePump.stopStreaming()
                result.success(null)
            }

            "isStreaming" -> result.success(NosmaiTexturePump.isStreaming)

            // Metadata only — WebRTC rotates at the receiver, so this takes
            // effect on the next frame with no restart and no re-publish.
            "setRotation" -> {
                NosmaiTexturePump.rotationDegrees = call.argument<Int>("degrees") ?: 0
                result.success(null)
            }

            "getPlatformVersion" -> result.success("Android ${android.os.Build.VERSION.RELEASE}")

            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        NosmaiTexturePump.stopStreaming()
    }
}
