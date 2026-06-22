#import "RTCFrameHelper.h"
#import <WebRTC/RTCVideoFrame.h>
#import <WebRTC/RTCCVPixelBuffer.h>
#import <Accelerate/Accelerate.h>

@implementation RTCFrameHelper

// Cached BGRA buffer for reuse (avoids allocation every frame).
static CVPixelBufferRef _cachedBGRABuffer = NULL;
static size_t _cachedWidth = 0;
static size_t _cachedHeight = 0;

// vImage converter state (reused across frames).
static vImageConverterRef _converter = NULL;
static vImage_YpCbCrPixelRange _pixelRange;
static vImage_YpCbCrToARGB _conversionInfo;
static BOOL _converterInitialized = NO;

+ (CVPixelBufferRef)pixelBufferFromFrame:(id)frame {
    if (!frame) {
        return NULL;
    }

    if (![frame isKindOfClass:[RTC_OBJC_TYPE(RTCVideoFrame) class]]) {
        return NULL;
    }

    RTC_OBJC_TYPE(RTCVideoFrame) *videoFrame = (RTC_OBJC_TYPE(RTCVideoFrame) *)frame;
    id<RTC_OBJC_TYPE(RTCVideoFrameBuffer)> buffer = videoFrame.buffer;

    if (![buffer isKindOfClass:[RTC_OBJC_TYPE(RTCCVPixelBuffer) class]]) {
        return NULL;
    }

    RTC_OBJC_TYPE(RTCCVPixelBuffer) *cvBuffer = (RTC_OBJC_TYPE(RTCCVPixelBuffer) *)buffer;
    CVPixelBufferRef pixelBuffer = cvBuffer.pixelBuffer;

    if (!pixelBuffer) {
        return NULL;
    }

    // Check if conversion is needed (NV12 → BGRA).
    if ([self isNV12Format:pixelBuffer]) {
        CVPixelBufferRef bgraBuffer = [self convertNV12ToBGRA:pixelBuffer];
        if (bgraBuffer) {
            return bgraBuffer;
        }
        // Conversion failed — fall through to return original (will likely not filter correctly).
        NSLog(@"[RTCFrameHelper] NV12→BGRA conversion failed, returning original buffer");
    }

    return pixelBuffer;
}

+ (BOOL)isNV12Format:(CVPixelBufferRef)pixelBuffer {
    OSType format = CVPixelBufferGetPixelFormatType(pixelBuffer);
    return (format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
            format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange);
}

+ (CVPixelBufferRef)originalPixelBufferFromFrame:(id)frame {
    if (!frame) {
        return NULL;
    }

    if (![frame isKindOfClass:[RTC_OBJC_TYPE(RTCVideoFrame) class]]) {
        return NULL;
    }

    RTC_OBJC_TYPE(RTCVideoFrame) *videoFrame = (RTC_OBJC_TYPE(RTCVideoFrame) *)frame;
    id<RTC_OBJC_TYPE(RTCVideoFrameBuffer)> buffer = videoFrame.buffer;

    if (![buffer isKindOfClass:[RTC_OBJC_TYPE(RTCCVPixelBuffer) class]]) {
        return NULL;
    }

    RTC_OBJC_TYPE(RTCCVPixelBuffer) *cvBuffer = (RTC_OBJC_TYPE(RTCCVPixelBuffer) *)buffer;
    return cvBuffer.pixelBuffer;
}

+ (CVPixelBufferRef)convertNV12ToBGRA:(CVPixelBufferRef)nv12Buffer {
    if (!nv12Buffer) {
        return NULL;
    }

    size_t width = CVPixelBufferGetWidth(nv12Buffer);
    size_t height = CVPixelBufferGetHeight(nv12Buffer);

    // Create or reuse the BGRA destination buffer.
    if (_cachedBGRABuffer == NULL || _cachedWidth != width || _cachedHeight != height) {
        if (_cachedBGRABuffer) {
            CVPixelBufferRelease(_cachedBGRABuffer);
            _cachedBGRABuffer = NULL;
        }

        NSDictionary *pixelBufferAttributes = @{
            (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
            (id)kCVPixelBufferMetalCompatibilityKey: @YES
        };

        CVReturn status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            (__bridge CFDictionaryRef)pixelBufferAttributes,
            &_cachedBGRABuffer
        );

        if (status != kCVReturnSuccess) {
            NSLog(@"[RTCFrameHelper] Failed to create BGRA buffer: %d", status);
            return NULL;
        }

        _cachedWidth = width;
        _cachedHeight = height;
        _converterInitialized = NO; // Force re-init of converter for new dimensions.

        NSLog(@"[RTCFrameHelper] Created BGRA buffer: %zux%zu", width, height);
    }

    // Initialize the vImage converter if needed.
    if (!_converterInitialized) {
        OSType sourceFormat = CVPixelBufferGetPixelFormatType(nv12Buffer);

        // Set pixel range based on format (full range vs video range).
        if (sourceFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
            _pixelRange = (vImage_YpCbCrPixelRange){0, 128, 255, 255, 255, 1, 255, 0};
        } else {
            // Video range (16-235 for Y, 16-240 for CbCr).
            _pixelRange = (vImage_YpCbCrPixelRange){16, 128, 235, 240, 255, 0, 255, 0};
        }

        vImage_Error err = vImageConvert_YpCbCrToARGB_GenerateConversion(
            kvImage_YpCbCrToARGBMatrix_ITU_R_709_2,  // HD color space (common for cameras).
            &_pixelRange,
            &_conversionInfo,
            kvImage420Yp8_CbCr8,  // NV12 input format.
            kvImageARGB8888,      // ARGB output (we'll reorder to BGRA).
            kvImageNoFlags
        );

        if (err != kvImageNoError) {
            NSLog(@"[RTCFrameHelper] Failed to generate vImage conversion: %ld", err);
            return NULL;
        }

        _converterInitialized = YES;
        NSLog(@"[RTCFrameHelper] vImage converter initialized for %zux%zu", width, height);
    }

    // Lock both buffers.
    CVReturn lockStatus = CVPixelBufferLockBaseAddress(nv12Buffer, kCVPixelBufferLock_ReadOnly);
    if (lockStatus != kCVReturnSuccess) {
        NSLog(@"[RTCFrameHelper] Failed to lock NV12 buffer: %d", lockStatus);
        return NULL;
    }

    lockStatus = CVPixelBufferLockBaseAddress(_cachedBGRABuffer, 0);
    if (lockStatus != kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(nv12Buffer, kCVPixelBufferLock_ReadOnly);
        NSLog(@"[RTCFrameHelper] Failed to lock BGRA buffer: %d", lockStatus);
        return NULL;
    }

    // Get plane pointers for NV12 (Y plane = 0, CbCr plane = 1).
    void *yPlane = CVPixelBufferGetBaseAddressOfPlane(nv12Buffer, 0);
    void *cbcrPlane = CVPixelBufferGetBaseAddressOfPlane(nv12Buffer, 1);
    size_t yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(nv12Buffer, 0);
    size_t cbcrBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(nv12Buffer, 1);

    // Get destination pointer.
    void *bgraData = CVPixelBufferGetBaseAddress(_cachedBGRABuffer);
    size_t bgraBytesPerRow = CVPixelBufferGetBytesPerRow(_cachedBGRABuffer);

    // Set up vImage buffers.
    vImage_Buffer yBuffer = {yPlane, height, width, yBytesPerRow};
    vImage_Buffer cbcrBuffer = {cbcrPlane, height / 2, width / 2, cbcrBytesPerRow};
    vImage_Buffer destBuffer = {bgraData, height, width, bgraBytesPerRow};

    // Convert NV12 to ARGB.
    // Note: This produces ARGB; we need BGRA for Nosmai.
    // We'll use the permuteMap to reorder channels.
    uint8_t permuteMap[4] = {3, 2, 1, 0};  // ARGB → BGRA

    vImage_Error err = vImageConvert_420Yp8_CbCr8ToARGB8888(
        &yBuffer,
        &cbcrBuffer,
        &destBuffer,
        &_conversionInfo,
        permuteMap,
        255,  // Alpha value.
        kvImageNoFlags
    );

    // Unlock buffers.
    CVPixelBufferUnlockBaseAddress(nv12Buffer, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(_cachedBGRABuffer, 0);

    if (err != kvImageNoError) {
        NSLog(@"[RTCFrameHelper] vImage conversion failed: %ld", err);
        return NULL;
    }

    return _cachedBGRABuffer;
}

+ (void)cleanup {
    if (_cachedBGRABuffer) {
        CVPixelBufferRelease(_cachedBGRABuffer);
        _cachedBGRABuffer = NULL;
    }
    _cachedWidth = 0;
    _cachedHeight = 0;
    _converterInitialized = NO;
}

+ (id)createFrameWithPixelBuffer:(CVPixelBufferRef)pixelBuffer
                   originalFrame:(id)originalFrame {
    if (!pixelBuffer || !originalFrame) {
        return nil;
    }

    if (![originalFrame isKindOfClass:[RTC_OBJC_TYPE(RTCVideoFrame) class]]) {
        return nil;
    }

    RTC_OBJC_TYPE(RTCVideoFrame) *srcFrame = (RTC_OBJC_TYPE(RTCVideoFrame) *)originalFrame;

    // Create RTCCVPixelBuffer wrapper.
    RTC_OBJC_TYPE(RTCCVPixelBuffer) *newBuffer =
        [[RTC_OBJC_TYPE(RTCCVPixelBuffer) alloc] initWithPixelBuffer:pixelBuffer];

    // Create new frame with same timestamp and rotation.
    RTC_OBJC_TYPE(RTCVideoFrame) *newFrame =
        [[RTC_OBJC_TYPE(RTCVideoFrame) alloc] initWithBuffer:newBuffer
                                                    rotation:srcFrame.rotation
                                                 timeStampNs:srcFrame.timeStampNs];

    return newFrame;
}

// vImage state for BGRA → NV12 reverse conversion.
static vImage_ARGBToYpCbCr _reverseConversionInfo;
static BOOL _reverseConverterInitialized = NO;

+ (BOOL)copyBGRAToNV12:(CVPixelBufferRef)bgraBuffer dest:(CVPixelBufferRef)nv12Buffer {
    if (!bgraBuffer || !nv12Buffer) {
        return NO;
    }

    size_t width = CVPixelBufferGetWidth(bgraBuffer);
    size_t height = CVPixelBufferGetHeight(bgraBuffer);

    // Initialize reverse converter if needed.
    if (!_reverseConverterInitialized) {
        OSType destFormat = CVPixelBufferGetPixelFormatType(nv12Buffer);
        vImage_YpCbCrPixelRange pixelRange;

        if (destFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
            pixelRange = (vImage_YpCbCrPixelRange){0, 128, 255, 255, 255, 1, 255, 0};
        } else {
            pixelRange = (vImage_YpCbCrPixelRange){16, 128, 235, 240, 255, 0, 255, 0};
        }

        vImage_Error err = vImageConvert_ARGBToYpCbCr_GenerateConversion(
            kvImage_ARGBToYpCbCrMatrix_ITU_R_709_2,
            &pixelRange,
            &_reverseConversionInfo,
            kvImageARGB8888,
            kvImage420Yp8_CbCr8,
            kvImageNoFlags
        );

        if (err != kvImageNoError) {
            NSLog(@"[RTCFrameHelper] Failed to generate reverse conversion: %ld", err);
            return NO;
        }

        _reverseConverterInitialized = YES;
    }

    // Lock both buffers.
    CVReturn status = CVPixelBufferLockBaseAddress(bgraBuffer, kCVPixelBufferLock_ReadOnly);
    if (status != kCVReturnSuccess) {
        return NO;
    }

    status = CVPixelBufferLockBaseAddress(nv12Buffer, 0);
    if (status != kCVReturnSuccess) {
        CVPixelBufferUnlockBaseAddress(bgraBuffer, kCVPixelBufferLock_ReadOnly);
        return NO;
    }

    // Get buffer pointers.
    void *bgraData = CVPixelBufferGetBaseAddress(bgraBuffer);
    size_t bgraBytesPerRow = CVPixelBufferGetBytesPerRow(bgraBuffer);

    void *yPlane = CVPixelBufferGetBaseAddressOfPlane(nv12Buffer, 0);
    void *cbcrPlane = CVPixelBufferGetBaseAddressOfPlane(nv12Buffer, 1);
    size_t yBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(nv12Buffer, 0);
    size_t cbcrBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(nv12Buffer, 1);

    // Set up vImage buffers.
    // BGRA needs permutation to ARGB for vImage (swap B and R).
    vImage_Buffer srcBuffer = {bgraData, height, width, bgraBytesPerRow};
    vImage_Buffer yBuffer = {yPlane, height, width, yBytesPerRow};
    vImage_Buffer cbcrBuffer = {cbcrPlane, height / 2, width / 2, cbcrBytesPerRow};

    // Permute BGRA → ARGB before conversion.
    uint8_t permuteMap[4] = {3, 2, 1, 0};  // BGRA → ARGB

    vImage_Error err = vImageConvert_ARGB8888To420Yp8_CbCr8(
        &srcBuffer,
        &yBuffer,
        &cbcrBuffer,
        &_reverseConversionInfo,
        permuteMap,
        kvImageNoFlags
    );

    // Unlock buffers.
    CVPixelBufferUnlockBaseAddress(bgraBuffer, kCVPixelBufferLock_ReadOnly);
    CVPixelBufferUnlockBaseAddress(nv12Buffer, 0);

    if (err != kvImageNoError) {
        NSLog(@"[RTCFrameHelper] Reverse conversion failed: %ld", err);
        return NO;
    }

    return YES;
}

@end
