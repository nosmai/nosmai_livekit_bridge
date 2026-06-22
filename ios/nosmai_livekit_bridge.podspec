#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint nosmai_livekit_bridge.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'nosmai_livekit_bridge'
  s.version          = '0.0.1'
  s.summary          = 'Nosmai filters integration for LiveKit'
  s.description      = <<-DESC
Easy integration of Nosmai filters with LiveKit for Flutter.
Apply real-time beauty filters to a LiveKit camera track without writing native code.
                       DESC
  s.homepage         = 'https://github.com/nosmai/nosmai_livekit_bridge'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Nosmai' => 'admin@nosmai.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*.{h,m,swift}'
  s.public_header_files = 'Classes/**/*.h'

  s.dependency 'Flutter'
  # Provides com.cloudwebrtc.webrtc <-> FlutterWebRTCPlugin / LocalVideoTrack headers,
  # and (transitively) the WebRTC-SDK pod whose <WebRTC/*.h> headers RTCFrameHelper uses.
  s.dependency 'flutter_webrtc'

  s.platform = :ios, '13.0'
  s.swift_version = '5.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386'
  }
  s.static_framework = true
end
