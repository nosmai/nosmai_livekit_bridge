#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * Owns the Nosmai → LiveKit video path on iOS.
 *
 * Nosmai owns the camera and the preview; this class only mints a WebRTC track
 * and pushes Nosmai's already-filtered CVPixelBuffers into it. LiveKit never
 * captures — a second capture path would mean a second Nosmai pipeline, which
 * on Android measured a ~2.4x frame-rate loss before it was removed.
 *
 * Per frame the work is O(1): wrap the pixel buffer (a refcount bump — it is
 * IOSurface-backed) and hand it to the video source. No copy, no conversion.
 */
@interface NosmaiLiveKitFramePump : NSObject

@property(class, nonatomic, readonly) NosmaiLiveKitFramePump *shared;

/**
 * Mint an RTCVideoSource/RTCVideoTrack, register it with flutter_webrtc, then
 * arm Nosmai's live-frame callback to feed it.
 *
 * Call on the platform thread. Returns the track id, or nil with |outError| set.
 */
- (nullable NSString *)startStreamingWithError:(NSError **)outError;

/** Disarm Nosmai first, then unregister the track. Safe when not streaming. */
- (void)stopStreaming;

@property(nonatomic, readonly) BOOL isStreaming;

/**
 * Rotation stamped on outgoing frames.
 *
 * Written on the platform thread, read on Nosmai's GL worker thread, so `atomic`
 * is load-bearing rather than decorative.
 */
@property(atomic, assign) NSInteger rotationDegrees;

@end

NS_ASSUME_NONNULL_END
