#import "NosmaiLiveKitBridgePlugin.h"
#import "NosmaiLiveKitFramePump.h"

/**
 * Nosmai ↔ LiveKit bridge, iOS.
 *
 * Satisfies the same method channel as Android. All logic lives in
 * NosmaiLiveKitFramePump; this class is only the channel surface.
 */
@implementation NosmaiLiveKitBridgePlugin

+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  FlutterMethodChannel *channel =
      [FlutterMethodChannel methodChannelWithName:@"nosmai_livekit_bridge"
                                  binaryMessenger:[registrar messenger]];
  NosmaiLiveKitBridgePlugin *instance = [[NosmaiLiveKitBridgePlugin alloc] init];
  [registrar addMethodCallDelegate:instance channel:channel];
}

- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  NosmaiLiveKitFramePump *pump = NosmaiLiveKitFramePump.shared;

  if ([@"registerShareContext" isEqualToString:call.method]) {
    // Android joins flutter_webrtc's EGL share group here so Nosmai's output
    // textures are usable by the encoder. iOS has no EGL and hands over
    // IOSurface-backed CVPixelBuffers, which need no shared context — so this is
    // a deliberate no-op, letting app code call it unconditionally.
    result(@(0));
    return;
  }

  if ([@"startStreaming" isEqualToString:call.method]) {
    NSError *error = nil;
    NSString *trackId = [pump startStreamingWithError:&error];
    if (!trackId) {
      result([FlutterError errorWithCode:@"START_FAILED"
                                 message:error.localizedDescription ?: @"unknown"
                                 details:nil]);
      return;
    }
    result(@{@"trackId": trackId, @"label": @"nosmai"});
    return;
  }

  if ([@"stopStreaming" isEqualToString:call.method]) {
    [pump stopStreaming];
    result(nil);
    return;
  }

  if ([@"isStreaming" isEqualToString:call.method]) {
    result(@(pump.isStreaming));
    return;
  }

  if ([@"setRotation" isEqualToString:call.method]) {
    NSNumber *degrees = call.arguments[@"degrees"];
    pump.rotationDegrees = degrees ? degrees.integerValue : 0;
    result(nil);
    return;
  }

  if ([@"getPlatformVersion" isEqualToString:call.method]) {
    result([@"iOS " stringByAppendingString:UIDevice.currentDevice.systemVersion]);
    return;
  }

  result(FlutterMethodNotImplemented);
}

@end
