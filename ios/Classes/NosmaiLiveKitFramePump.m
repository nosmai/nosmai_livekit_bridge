#import "NosmaiLiveKitFramePump.h"

#import <WebRTC/WebRTC.h>
#import <objc/message.h>

#import "FlutterWebRTCPlugin.h"
#import "LocalVideoTrack.h"

static NSString *const kErrDomain = @"NosmaiLiveKitFramePump";

@interface NosmaiLiveKitFramePump ()
@property(nonatomic, strong, nullable) RTCVideoSource *videoSource;
@property(nonatomic, strong, nullable) RTCVideoTrack *videoTrack;
// A capturer is a required argument of -capturer:didCaptureVideoFrame: but is
// only used by the source for adaptation bookkeeping; it never captures. Held
// for the pump's lifetime so the argument is never a dangling reference.
@property(nonatomic, strong, nullable) RTCVideoCapturer *dummyCapturer;
@property(nonatomic, copy, nullable) NSString *trackId;
@property(nonatomic, assign) BOOL streaming;
@property(nonatomic, assign) NSUInteger frameCount;
@end

@implementation NosmaiLiveKitFramePump

+ (NosmaiLiveKitFramePump *)shared {
  static NosmaiLiveKitFramePump *instance;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ instance = [[NosmaiLiveKitFramePump alloc] init]; });
  return instance;
}

- (instancetype)init {
  if ((self = [super init])) {
    // 0 is correct: Nosmai delivers upright portrait frames, so any non-zero
    // value ADDS a rotation rather than correcting one. Verified on Android;
    // confirm on iOS from the delivered dimensions.
    _rotationDegrees = 0;
  }
  return self;
}

- (BOOL)isStreaming { return _streaming; }

#pragma mark - Nosmai access (reflection)

/**
 * camsdk_v2's plugin class, reached by name.
 *
 * The podspec depends on flutter_webrtc only, not on nosmai_camera_sdk, so there
 * is no compile-time symbol to link against. The working Agora bridge reaches it
 * the same way (bridge_v2/ios/Classes/VideoRawDataController.m:44-66).
 */
static Class NosmaiPluginClass(void) {
  return NSClassFromString(@"NosmaiFlutterPlugin");
}

/**
 * Arm Nosmai's live-frame output.
 *
 * MUST route through +setLiveStreamFrameCallback: rather than
 * +setCVPixelBufferCallback:. The latter overwrites NosmaiCore's single fan-out
 * slot and silently breaks video recording; the former fans out to both the
 * recorder and this stream.
 */
static BOOL ArmNosmaiLiveFrames(void (^callback)(CVPixelBufferRef, double)) {
  Class cls = NosmaiPluginClass();
  SEL sel = @selector(setLiveStreamFrameCallback:);
  if (!cls || ![cls respondsToSelector:sel]) return NO;
  void (*fn)(Class, SEL, id) = (void (*)(Class, SEL, id))objc_msgSend;
  fn(cls, sel, callback);
  return YES;
}

static void DisarmNosmaiLiveFrames(void) {
  Class cls = NosmaiPluginClass();
  SEL sel = @selector(clearLiveStreamFrameCallback);
  if (cls && [cls respondsToSelector:sel]) {
    void (*fn)(Class, SEL) = (void (*)(Class, SEL))objc_msgSend;
    fn(cls, sel);
  }
}

#pragma mark - Start / stop

- (nullable NSString *)startStreamingWithError:(NSError **)outError {
  if (_streaming) [self stopStreaming];

  FlutterWebRTCPlugin *plugin = [FlutterWebRTCPlugin sharedSingleton];
  if (!plugin) {
    if (outError) *outError = [NSError errorWithDomain:kErrDomain code:1
        userInfo:@{NSLocalizedDescriptionKey: @"FlutterWebRTCPlugin.sharedSingleton is nil"}];
    return nil;
  }

  // Created lazily by flutter_webrtc, so the Dart side must have made some
  // WebRTC call before this runs.
  RTCPeerConnectionFactory *factory = plugin.peerConnectionFactory;
  if (!factory) {
    if (outError) *outError = [NSError errorWithDomain:kErrDomain code:2
        userInfo:@{NSLocalizedDescriptionKey: @"peerConnectionFactory is nil (WebRTC not initialized)"}];
    return nil;
  }

  RTCVideoSource *source = [factory videoSource];
  NSString *trackId = [NSString stringWithFormat:@"nosmai-%@", [[NSUUID UUID] UUIDString]];
  RTCVideoTrack *track = [factory videoTrackWithSource:source trackId:trackId];

  // Unlike Android — where the registry lives behind a private field and needs
  // reflection — localTracks is a public readwrite property on iOS
  // (FlutterWebRTCPlugin.h:38), so registration is a plain dictionary write.
  if (!plugin.localTracks) plugin.localTracks = [NSMutableDictionary dictionary];
  plugin.localTracks[trackId] = [[LocalVideoTrack alloc] initWithTrack:track];

  self.videoSource = source;
  self.videoTrack = track;
  self.trackId = trackId;
  self.dummyCapturer = [[RTCVideoCapturer alloc] initWithDelegate:nil];
  self.frameCount = 0;
  self.streaming = YES;

  __weak typeof(self) weakSelf = self;
  BOOL armed = ArmNosmaiLiveFrames(^(CVPixelBufferRef pixelBuffer, double timestamp) {
    [weakSelf onNosmaiFrame:pixelBuffer timestamp:timestamp];
  });

  if (!armed) {
    self.streaming = NO;
    [self stopStreaming];
    if (outError) *outError = [NSError errorWithDomain:kErrDomain code:3
        userInfo:@{NSLocalizedDescriptionKey:
            @"NosmaiFlutterPlugin does not respond to setLiveStreamFrameCallback: "
            @"— is nosmai_camera_sdk present and initialized?"}];
    return nil;
  }

  NSLog(@"[NosmaiLiveKit] ✅ streaming: track %@ armed (rotation=%ld)",
        trackId, (long)self.rotationDegrees);
  return trackId;
}

- (void)stopStreaming {
  // Disarm the PRODUCER first: with the callback still live, tearing down the
  // source underneath it would race a frame already in flight.
  DisarmNosmaiLiveFrames();
  self.streaming = NO;

  if (self.trackId) {
    FlutterWebRTCPlugin *plugin = [FlutterWebRTCPlugin sharedSingleton];
    [plugin.localTracks removeObjectForKey:self.trackId];
  }
  self.videoTrack = nil;
  self.videoSource = nil;
  self.dummyCapturer = nil;
  self.trackId = nil;
  NSLog(@"[NosmaiLiveKit] stopped (pushed %lu frames)", (unsigned long)self.frameCount);
}

#pragma mark - Frame path

/**
 * Called on Nosmai's GL WORKER thread, with the camera thread blocked behind a
 * synchronous context round-trip. Anything slow here directly costs preview fps,
 * so this does the minimum: wrap and hand off.
 *
 * RTCCVPixelBuffer retains the buffer, and the source/encoder retain the frame
 * for as long as they need it, so pushing synchronously is safe — no copy ring
 * is required. The producer pool is only 4 deep and drops silently when full, so
 * holding a buffer beyond this call would risk a permanent, silent freeze.
 */
- (void)onNosmaiFrame:(CVPixelBufferRef)pixelBuffer timestamp:(double)timestamp {
  if (!_streaming || pixelBuffer == NULL) return;

  RTCVideoSource *source = self.videoSource;
  RTCVideoCapturer *capturer = self.dummyCapturer;
  if (!source || !capturer) return;

  RTCCVPixelBuffer *buffer = [[RTCCVPixelBuffer alloc] initWithPixelBuffer:pixelBuffer];

  RTCVideoRotation rotation = RTCVideoRotation_0;
  switch (self.rotationDegrees) {
    case 90:  rotation = RTCVideoRotation_90;  break;
    case 180: rotation = RTCVideoRotation_180; break;
    case 270: rotation = RTCVideoRotation_270; break;
    default:  rotation = RTCVideoRotation_0;   break;
  }

  RTCVideoFrame *frame =
      [[RTCVideoFrame alloc] initWithBuffer:buffer
                                   rotation:rotation
                                timeStampNs:(int64_t)(timestamp * NSEC_PER_SEC)];

  [source capturer:capturer didCaptureVideoFrame:frame];

  if (++self.frameCount % 60 == 0) {
    NSLog(@"[NosmaiLiveKit] pushed %lu frames (%zux%zu)",
          (unsigned long)self.frameCount,
          CVPixelBufferGetWidth(pixelBuffer),
          CVPixelBufferGetHeight(pixelBuffer));
  }
}

@end
