package com.example.nosmai_livekit_bridge;

import android.graphics.Matrix;
import android.opengl.GLES20;
import android.opengl.GLES30;
import android.util.Log;

import org.webrtc.CapturerObserver;
import org.webrtc.SurfaceTextureHelper;
import org.webrtc.TextureBufferImpl;
import org.webrtc.VideoFrame;
import org.webrtc.YuvConverter;

import java.util.concurrent.atomic.AtomicBoolean;

/**
 * STEP 4 — zero-readback texture path.
 *
 * Direct port of the working Agora bridge (bridge_v2/.../AgoraTextureBridge.java)
 * with three substitutions:
 *   TextureBufferHelper          -> SurfaceTextureHelper
 *   io.agora.base.TextureBuffer  -> org.webrtc.TextureBufferImpl
 *   engine.pushExternalVideoFrame-> capturerObserver.onFrameCaptured
 *
 * Per frame: ONE glBlitFramebuffer. No glReadPixels, no I420 convert, no CPU
 * copies — versus the step-3 CPU path's readback + colour convert + 3 allocs +
 * 3 plane copies, which measured ~8fps on a Pixel 5.
 *
 * Why copy at all instead of handing Nosmai's texture straight to WebRTC: the
 * encoder may hold a frame across several vsyncs, while Nosmai wants its ring
 * slot back immediately. Blitting into a helper-owned ring decouples the two
 * lifetimes; the same reasoning is why the Agora bridge does it.
 */
final class NosmaiTextureBridge {
    private static final String TAG = "NosmaiTexBridge";
    private static final int RING = 3;
    private static final long SLOT_STALL_MS = 500;

    private final SurfaceTextureHelper helper;
    private final CapturerObserver observer;
    private final YuvConverter yuvConverter;

    private final int[] tex = new int[RING];
    private final int[] fbo = new int[RING];
    private final AtomicBoolean[] busy = new AtomicBoolean[RING];
    private final long[] busySince = new long[RING];

    // Single-flight: if the previous push is still in flight we DROP rather than
    // queue. Backing up would stall Nosmai's GL worker, which is the thread that
    // renders the filter — latency there is worse than a dropped frame.
    private final AtomicBoolean inFlight = new AtomicBoolean(false);

    private int ringW, ringH, srcFbo;
    private volatile boolean released;
    private int pushCount, dropCount;

    /**
     * Rotation stamped on outgoing frames; WebRTC applies it at the receiver.
     *
     * ZERO is correct for this path, confirmed on-device. Nosmai's streaming
     * pass already rotates its landscape source into a portrait 720x1280 FBO
     * (sink_raw_data.cc:568-593), so the texture handed to WebRTC is upright and
     * needs no further correction.
     *
     * The rotation seen on remotes earlier belonged to the old CPU/in-place
     * paths, which are deleted. Setting 90 here to "fix" it INTRODUCED a
     * quarter-turn rather than removing one.
     *
     * Metadata only — the receiver rotates on display, so this is free to change
     * and takes effect on the next frame.
     */
    volatile int rotationDegrees = 0;

    NosmaiTextureBridge(SurfaceTextureHelper helper, CapturerObserver observer,
                        YuvConverter yuvConverter) {
        this.helper = helper;
        this.observer = observer;
        this.yuvConverter = yuvConverter;
        for (int i = 0; i < RING; i++) busy[i] = new AtomicBoolean(false);
    }

    /**
     * @param onSourceConsumed MUST run exactly once — it returns Nosmai's ring
     *                         slot. Leaking it starves the producer within a few
     *                         frames and the stream freezes with no error.
     */
    void pushCopy(final int srcTexId, final int width, final int height,
                  final long timestampNs, final Runnable onSourceConsumed) {
        if (released) { run(onSourceConsumed); return; }
        if (!inFlight.compareAndSet(false, true)) {
            dropCount++;
            run(onSourceConsumed);
            return;
        }

        // Hop to the helper's GL thread — that context is in flutter_webrtc's
        // share group, so the destination textures are the ones the encoder can
        // actually read.
        helper.getHandler().post(() -> {
            try {
                ensureRing(width, height);
                final int slot = acquireSlot();
                if (slot < 0) {
                    if (dropCount++ % 60 == 0) Log.w(TAG, "ring busy, dropping frame");
                    return;
                }

                if (srcFbo == 0) {
                    int[] f = new int[1];
                    GLES20.glGenFramebuffers(1, f, 0);
                    srcFbo = f[0];
                }

                GLES30.glBindFramebuffer(GLES30.GL_READ_FRAMEBUFFER, srcFbo);
                GLES30.glFramebufferTexture2D(GLES30.GL_READ_FRAMEBUFFER,
                        GLES30.GL_COLOR_ATTACHMENT0, GLES20.GL_TEXTURE_2D, srcTexId, 0);
                GLES30.glBindFramebuffer(GLES30.GL_DRAW_FRAMEBUFFER, fbo[slot]);
                // Y-FLIPPED (dst y range reversed): GL textures are bottom-up,
                // WebRTC expects top-down. The Agora bridge does the same flip
                // here and it is the ONLY flip in the chain.
                GLES30.glBlitFramebuffer(0, 0, width, height,
                        0, height, width, 0,
                        GLES20.GL_COLOR_BUFFER_BIT, GLES20.GL_NEAREST);
                GLES30.glFramebufferTexture2D(GLES30.GL_READ_FRAMEBUFFER,
                        GLES30.GL_COLOR_ATTACHMENT0, GLES20.GL_TEXTURE_2D, 0, 0);
                GLES30.glBindFramebuffer(GLES30.GL_READ_FRAMEBUFFER, 0);
                GLES30.glBindFramebuffer(GLES30.GL_DRAW_FRAMEBUFFER, 0);
                GLES20.glFlush();

                final int s = slot;
                TextureBufferImpl buffer = new TextureBufferImpl(
                        width, height,
                        VideoFrame.TextureBuffer.Type.RGB,
                        tex[slot],
                        new Matrix(),
                        helper.getHandler(),
                        yuvConverter,
                        () -> { busySince[s] = 0; busy[s].set(false); });

                VideoFrame frame = new VideoFrame(buffer, rotationDegrees, timestampNs);
                try {
                    observer.onFrameCaptured(frame);
                    if (++pushCount % 60 == 0) {
                        Log.i(TAG, "pushed " + pushCount + " texture frames ("
                                + width + "x" + height + "), dropped " + dropCount);
                    }
                } finally {
                    // Release OUR reference; the encoder retains its own if it
                    // needs the frame longer, and the slot frees via the callback.
                    frame.release();
                }
            } catch (Throwable t) {
                Log.e(TAG, "pushCopy failed", t);
            } finally {
                inFlight.set(false);
                run(onSourceConsumed);
            }
        });
    }

    private static void run(Runnable r) { if (r != null) r.run(); }

    private void ensureRing(int width, int height) {
        if (ringW == width && ringH == height && tex[0] != 0) return;
        if (tex[0] != 0) {
            GLES20.glDeleteTextures(RING, tex, 0);
            GLES20.glDeleteFramebuffers(RING, fbo, 0);
        }
        GLES20.glGenTextures(RING, tex, 0);
        GLES20.glGenFramebuffers(RING, fbo, 0);
        for (int i = 0; i < RING; i++) {
            GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, tex[i]);
            GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, width, height,
                    0, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, null);
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MIN_FILTER, GLES20.GL_LINEAR);
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_MAG_FILTER, GLES20.GL_LINEAR);
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_S, GLES20.GL_CLAMP_TO_EDGE);
            GLES20.glTexParameteri(GLES20.GL_TEXTURE_2D, GLES20.GL_TEXTURE_WRAP_T, GLES20.GL_CLAMP_TO_EDGE);
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, fbo[i]);
            GLES20.glFramebufferTexture2D(GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0,
                    GLES20.GL_TEXTURE_2D, tex[i], 0);
            busy[i].set(false);
            busySince[i] = 0;
        }
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, 0);
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0);
        ringW = width;
        ringH = height;
        Log.i(TAG, "ring created " + width + "x" + height);
    }

    /**
     * Reclaim a slot the encoder never released. Without this a single dropped
     * release permanently shrinks the ring until the stream stalls.
     */
    private int acquireSlot() {
        final long now = android.os.SystemClock.uptimeMillis();
        for (int i = 0; i < RING; i++) {
            if (busy[i].compareAndSet(false, true)) { busySince[i] = now; return i; }
        }
        int oldest = -1;
        long oldestSince = Long.MAX_VALUE;
        for (int i = 0; i < RING; i++) {
            long since = busySince[i];
            if (since != 0 && (now - since) > SLOT_STALL_MS && since < oldestSince) {
                oldestSince = since;
                oldest = i;
            }
        }
        if (oldest >= 0) {
            Log.w(TAG, "reclaiming stalled slot " + oldest + " (" + (now - oldestSince) + "ms)");
            busySince[oldest] = now;
            return oldest;
        }
        return -1;
    }

    void release() {
        released = true;
        try {
            helper.getHandler().post(() -> {
                if (tex[0] != 0) {
                    GLES20.glDeleteTextures(RING, tex, 0);
                    GLES20.glDeleteFramebuffers(RING, fbo, 0);
                    for (int i = 0; i < RING; i++) { tex[i] = 0; fbo[i] = 0; busy[i].set(false); }
                }
                if (srcFbo != 0) {
                    GLES20.glDeleteFramebuffers(1, new int[]{srcFbo}, 0);
                    srcFbo = 0;
                }
                ringW = 0;
                ringH = 0;
            });
        } catch (Throwable ignored) {}
        Log.i(TAG, "released (pushed " + pushCount + ", dropped " + dropCount + ")");
    }
}
