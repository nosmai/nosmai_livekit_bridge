package com.example.nosmai_livekit_bridge

import java.nio.ByteBuffer

/**
 * Calls Nosmai SDK methods via reflection so the bridge does NOT need a
 * compile-time dependency on the Nosmai AAR.
 *
 * The Nosmai AAR is already loaded at runtime by the nosmai_camera_sdk Flutter
 * plugin. These calls reach into the existing loaded classes.
 */
object NosmaiReflection {

    private var nosmaiClass: Class<*>? = null

    private fun getNosmaiClass(): Class<*>? {
        if (nosmaiClass != null) return nosmaiClass

        val possibleClassNames = listOf(
            "com.nosmai.effect.api.NosmaiSDK",  // Most likely
            "com.nosmai.sdk.NosmaiSDK",
            "com.nosmai.NosmaiSDK"
        )

        for (className in possibleClassNames) {
            try {
                val cls = Class.forName(className)
                nosmaiClass = cls
                println("[NosmaiReflection] Found Nosmai class: $className")
                return cls
            } catch (e: ClassNotFoundException) {
                // Try next one
            }
        }

        println("[NosmaiReflection] NosmaiSDK class not found in any expected location")
        return null
    }

    /**
     * Calls NosmaiSDK.processExternalI420InPlace().
     * Returns true if Nosmai processed the frame, false if unavailable or error.
     */
    fun processExternalI420InPlace(
        yBuffer: ByteBuffer,
        uBuffer: ByteBuffer,
        vBuffer: ByteBuffer,
        width: Int,
        height: Int,
        yStride: Int,
        uStride: Int,
        vStride: Int,
        rotation: Int,
        isFrontCamera: Boolean
    ): Boolean {
        val cls = getNosmaiClass() ?: return false

        return try {
            val method = cls.getMethod(
                "processExternalI420InPlace",
                ByteBuffer::class.java,
                ByteBuffer::class.java,
                ByteBuffer::class.java,
                Int::class.javaPrimitiveType,
                Int::class.javaPrimitiveType,
                Int::class.javaPrimitiveType,
                Int::class.javaPrimitiveType,
                Int::class.javaPrimitiveType,
                Int::class.javaPrimitiveType,
                Boolean::class.javaPrimitiveType
            )
            method.invoke(
                null,  // static method
                yBuffer, uBuffer, vBuffer,
                width, height,
                yStride, uStride, vStride,
                rotation, isFrontCamera
            ) as? Boolean ?: false
        } catch (e: Exception) {
            println("[NosmaiReflection] processExternalI420InPlace failed: ${e.message}")
            e.printStackTrace()
            false
        }
    }

    // NOTE: NosmaiSDK (com.nosmai.effect.api.NosmaiSDK in nosmai-release.aar v3.0.5) has
    // NO notifyCameraSwitch() method. Camera facing is updated via setCameraFacing(boolean).

    /** Initialize the external frame pipeline. */
    fun initializeExternalFramePipeline(width: Int, height: Int): Boolean {
        val cls = getNosmaiClass() ?: return false
        return try {
            val method = cls.getMethod(
                "initializeExternalFramePipeline",
                Int::class.javaPrimitiveType,
                Int::class.javaPrimitiveType
            )
            method.invoke(null, width, height) as? Boolean ?: false
        } catch (e: Exception) {
            println("[NosmaiReflection] initializeExternalFramePipeline failed: ${e.message}")
            false
        }
    }

    /**
     * Returns whether Nosmai's external frame pipeline is ready. When true, applyEffect()
     * routes filters to the external (streaming) pipeline; when false it falls back to the
     * internal camera pipeline and applied filters are not visible on the streamed frames.
     */
    fun isExternalFramePipelineReady(): Boolean {
        val cls = getNosmaiClass() ?: return false
        return try {
            val method = cls.getMethod("isExternalFramePipelineReady")
            method.invoke(null) as? Boolean ?: false
        } catch (e: Exception) {
            println("[NosmaiReflection] isExternalFramePipelineReady failed: ${e.message}")
            false
        }
    }

    /** Set external frame mode. */
    fun setExternalFrameMode(enabled: Boolean) {
        val cls = getNosmaiClass() ?: return
        try {
            val method = cls.getMethod("setExternalFrameMode", Boolean::class.javaPrimitiveType)
            method.invoke(null, enabled)
        } catch (e: Exception) {
            println("[NosmaiReflection] setExternalFrameMode failed: ${e.message}")
        }
    }

    /** Set camera facing. */
    fun setCameraFacing(isFront: Boolean) {
        val cls = getNosmaiClass() ?: return
        try {
            val method = cls.getMethod("setCameraFacing", Boolean::class.javaPrimitiveType)
            method.invoke(null, isFront)
        } catch (e: Exception) {
            println("[NosmaiReflection] setCameraFacing failed: ${e.message}")
        }
    }

    /** Set mirror X. */
    fun setMirrorX(enabled: Boolean) {
        val cls = getNosmaiClass() ?: return
        try {
            val method = cls.getMethod("setMirrorX", Boolean::class.javaPrimitiveType)
            method.invoke(null, enabled)
        } catch (e: Exception) {
            println("[NosmaiReflection] setMirrorX failed: ${e.message}")
        }
    }
}
