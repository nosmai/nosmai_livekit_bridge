#import "NosmaiLiveKitBridgePlugin.h"
#import <flutter_webrtc/FlutterWebRTCPlugin.h>
#import <flutter_webrtc/LocalVideoTrack.h>
#import <flutter_webrtc/VideoProcessingAdapter.h>

// Generated header that exposes this plugin's Swift classes (NosmaiVideoProcessor).
#if __has_include(<nosmai_livekit_bridge/nosmai_livekit_bridge-Swift.h>)
#import <nosmai_livekit_bridge/nosmai_livekit_bridge-Swift.h>
#else
#import "nosmai_livekit_bridge-Swift.h"
#endif

@interface NosmaiLiveKitBridgePlugin ()
// Video processor for flutter_webrtc integration (same pattern as Android).
@property(nonatomic, strong) NosmaiVideoProcessor* nosmaiProcessor;
// Keep reference to the attached track so we can detach the processor on release.
@property(nonatomic, weak) LocalVideoTrack* attachedTrack;
@end

@implementation NosmaiLiveKitBridgePlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
  FlutterMethodChannel* channel =
      [FlutterMethodChannel methodChannelWithName:@"nosmai_livekit_bridge"
                                  binaryMessenger:[registrar messenger]];
  NosmaiLiveKitBridgePlugin* instance = [[NosmaiLiveKitBridgePlugin alloc] init];
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {
  if ([@"getPlatformVersion" isEqualToString:call.method]) {
    result([@"iOS " stringByAppendingString:[[UIDevice currentDevice] systemVersion]]);
  }
  // ── attachNosmaiProcessing ─────────────────────────────────────────────
  // Attaches Nosmai processing to a flutter_webrtc LocalVideoTrack.
  // iOS equivalent of Android's ExternalVideoFrameProcessing pattern.
  else if ([@"attachNosmaiProcessing" isEqualToString:call.method]) {
    @try {
      NSDictionary *args = call.arguments;
      NSString *videoTrackId = args[@"videoTrackId"];
      BOOL isFrontCamera = [args[@"isFrontCamera"] boolValue];

      if (!videoTrackId || videoTrackId.length == 0) {
        result([FlutterError errorWithCode:@"INVALID_ARGS"
                                   message:@"videoTrackId is required"
                                   details:nil]);
        return;
      }

      FlutterWebRTCPlugin *webrtcPlugin = [FlutterWebRTCPlugin sharedSingleton];
      if (!webrtcPlugin) {
        result([FlutterError errorWithCode:@"NOT_INITIALIZED"
                                   message:@"FlutterWebRTCPlugin not initialized"
                                   details:nil]);
        return;
      }

      id<LocalTrack> track = webrtcPlugin.localTracks[videoTrackId];
      if (!track) {
        result([FlutterError errorWithCode:@"TRACK_NOT_FOUND"
                                   message:[NSString stringWithFormat:@"Track '%@' not found in flutter_webrtc registry", videoTrackId]
                                   details:nil]);
        return;
      }

      if (![track isKindOfClass:[LocalVideoTrack class]]) {
        result([FlutterError errorWithCode:@"INVALID_TRACK"
                                   message:@"Expected LocalVideoTrack"
                                   details:nil]);
        return;
      }

      LocalVideoTrack *localVideoTrack = (LocalVideoTrack *)track;

      // Detach any previous processor before attaching a new one.
      if (self.nosmaiProcessor && self.attachedTrack) {
        [self.attachedTrack removeProcessing:(id<ExternalVideoProcessingDelegate>)self.nosmaiProcessor];
        [self.nosmaiProcessor releaseProcessor];
        self.nosmaiProcessor = nil;
      }

      NosmaiVideoProcessor *processor =
          [[NosmaiVideoProcessor alloc] initWithIsFrontCamera:isFrontCamera];
      self.nosmaiProcessor = processor;
      self.attachedTrack = localVideoTrack;

      [localVideoTrack addProcessing:(id<ExternalVideoProcessingDelegate>)processor];

      NSLog(@"[NosmaiPlugin] Nosmai processor attached to track %@", videoTrackId);
      result(@(YES));
    } @catch (NSException *exception) {
      NSLog(@"[NosmaiPlugin] attachNosmaiProcessing exception: %@", exception.reason);
      result([FlutterError errorWithCode:@"ATTACH_ERROR"
                                 message:[NSString stringWithFormat:@"Exception: %@", exception.reason]
                                 details:nil]);
    }
  }
  // ── updateNosmaiCameraFacing ───────────────────────────────────────────
  else if ([@"updateNosmaiCameraFacing" isEqualToString:call.method]) {
    @try {
      NSDictionary *args = call.arguments;
      BOOL isFrontCamera = [args[@"isFrontCamera"] boolValue];
      if (self.nosmaiProcessor) {
        [self.nosmaiProcessor updateCameraFacing:isFrontCamera];
      }
      result(@(YES));
    } @catch (NSException *exception) {
      result([FlutterError errorWithCode:@"UPDATE_ERROR"
                                 message:[NSString stringWithFormat:@"Exception: %@", exception.reason]
                                 details:nil]);
    }
  }
  // ── releaseNosmaiProcessing ────────────────────────────────────────────
  else if ([@"releaseNosmaiProcessing" isEqualToString:call.method]) {
    @try {
      if (self.nosmaiProcessor && self.attachedTrack) {
        [self.attachedTrack removeProcessing:(id<ExternalVideoProcessingDelegate>)self.nosmaiProcessor];
      }
      if (self.nosmaiProcessor) {
        [self.nosmaiProcessor releaseProcessor];
      }
      self.nosmaiProcessor = nil;
      self.attachedTrack = nil;
      result(@(YES));
    } @catch (NSException *exception) {
      result([FlutterError errorWithCode:@"RELEASE_ERROR"
                                 message:[NSString stringWithFormat:@"Exception: %@", exception.reason]
                                 details:nil]);
    }
  }
  else {
    result(FlutterMethodNotImplemented);
  }
}

- (void)dealloc {
  if (self.nosmaiProcessor && self.attachedTrack) {
    [self.attachedTrack removeProcessing:(id<ExternalVideoProcessingDelegate>)self.nosmaiProcessor];
  }
  if (self.nosmaiProcessor) {
    [self.nosmaiProcessor releaseProcessor];
  }
  self.nosmaiProcessor = nil;
  self.attachedTrack = nil;
}

@end
