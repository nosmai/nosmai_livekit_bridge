#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

/// Helper class to extract a CVPixelBuffer from an RTCVideoFrame.
/// This lives in Objective-C because it can import WebRTC headers without the
/// module conflicts Swift hits when multiple WebRTC builds are present.
@interface RTCFrameHelper : NSObject

/// Extracts the CVPixelBuffer from an RTCVideoFrame, converting NV12 to BGRA if needed.
/// Nosmai SDK expects BGRA format, but flutter_webrtc's camera delivers NV12.
/// @param frame The RTCVideoFrame object.
/// @return A BGRA CVPixelBuffer ready for Nosmai processing, or NULL if unavailable.
+ (nullable CVPixelBufferRef)pixelBufferFromFrame:(id)frame CF_RETURNS_NOT_RETAINED;

/// Converts an NV12 pixel buffer to BGRA format.
/// @param nv12Buffer The source NV12 pixel buffer.
/// @return A new BGRA pixel buffer, or NULL on failure. Caller must release.
+ (nullable CVPixelBufferRef)convertNV12ToBGRA:(CVPixelBufferRef)nv12Buffer CF_RETURNS_RETAINED;

/// Returns YES if the pixel buffer is in NV12 format.
+ (BOOL)isNV12Format:(CVPixelBufferRef)pixelBuffer;

/// Releases cached conversion buffers. Call when releasing the processor.
+ (void)cleanup;

/// Extracts the original CVPixelBuffer from an RTCVideoFrame WITHOUT any conversion.
/// Use this when you need the raw buffer (e.g., to check format or write back to it).
/// @param frame The RTCVideoFrame object.
/// @return The original CVPixelBuffer, or NULL if unavailable.
+ (nullable CVPixelBufferRef)originalPixelBufferFromFrame:(id)frame CF_RETURNS_NOT_RETAINED;

/// Creates a new RTCVideoFrame with the given pixel buffer, copying metadata from the original frame.
/// @param pixelBuffer The CVPixelBuffer to wrap.
/// @param originalFrame The original RTCVideoFrame to copy timestamp/rotation from.
/// @return A new RTCVideoFrame, or nil on failure.
+ (nullable id)createFrameWithPixelBuffer:(CVPixelBufferRef)pixelBuffer
                            originalFrame:(id)originalFrame;

/// Copies processed BGRA data back to the original NV12 buffer (reverse conversion).
/// This is needed because the frame returned must use the original buffer for the WebRTC pipeline.
/// @param bgraBuffer The processed BGRA buffer.
/// @param nv12Buffer The original NV12 buffer to write to.
/// @return YES on success, NO on failure.
+ (BOOL)copyBGRAToNV12:(CVPixelBufferRef)bgraBuffer dest:(CVPixelBufferRef)nv12Buffer;

@end

NS_ASSUME_NONNULL_END
