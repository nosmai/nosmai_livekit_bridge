import 'dart:io';

import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:nosmai_camera_sdk/nosmai_camera_sdk.dart';
import 'package:nosmai_livekit_bridge/nosmai_livekit_bridge.dart';
import 'package:permission_handler/permission_handler.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nosmai LiveKit Bridge Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const LiveKitScreen(),
    );
  }
}

/// Nosmai owns the camera AND the preview; LiveKit only publishes.
///
/// The single most important structural rule here: this app NEVER calls
/// LocalVideoTrack.createCameraTrack(). Doing so opens a second camera and a
/// second Nosmai pipeline that contends for the one GL worker — measured at
/// roughly a third of the achievable frame rate. LiveKit receives Nosmai's
/// already-filtered output as a GPU texture instead.
class LiveKitScreen extends StatefulWidget {
  const LiveKitScreen({super.key});

  @override
  State<LiveKitScreen> createState() => _LiveKitScreenState();
}

class _LiveKitScreenState extends State<LiveKitScreen> {
  // ── Server ────────────────────────────────────────────────────────────
  //   brew install livekit livekit-cli
  //   livekit-server --dev --bind 0.0.0.0
  //   lk token create --api-key devkey --api-secret secret \
  //     --join --room nosmai-test --identity phone --valid-for 720h
  // A device cannot reach the host over localhost, so use the LAN IP.
  // Your LiveKit server. A device cannot reach the host over localhost, so use
  // the machine's LAN IP when running a local dev server.
  final _urlCtrl = TextEditingController(text: 'ws://192.168.1.100:7880');
  final _tokenCtrl = TextEditingController();

  // Nosmai licence keys are PLATFORM-SPECIFIC and bound to your app's bundle id,
  // so an Android key is rejected on iOS and vice versa. Set the matching bundle
  // id in android/app/build.gradle.kts and ios/Runner.xcodeproj.
  final String _nosmaiKey = Platform.isIOS
      ? 'YOUR_NOSMAI_IOS_KEY'
      : 'YOUR_NOSMAI_ANDROID_KEY';

  Room? _room;
  LocalVideoTrack? _publishedTrack;
  bool _streaming = false;
  bool _busy = false;
  bool _nosmaiReady = false;
  String _status = 'Starting…';
  // 0 = no correction. Nosmai's streaming pass already delivers upright
  // portrait frames; the rotation seen on remotes previously came from the old
  // CPU/in-place paths, which no longer exist.
  int _rotation = 0;

  List<NosmaiFilter> _filters = [];
  String? _activeFilterPath;

  @override
  void initState() {
    super.initState();
    _initNosmai();
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _tokenCtrl.dispose();
    _teardown();
    super.dispose();
  }

  void _log(String msg) {
    debugPrint('[LiveKitExample] $msg');
    if (mounted) setState(() => _status = msg);
  }

  Future<void> _initNosmai() async {
    try {
      await [Permission.camera, Permission.microphone].request();

      // ORDER IS LOAD-BEARING. The EGL share handle is consumed when Nosmai's
      // GL context is constructed, so this must precede initialize(). Called
      // late, it is ignored and the remote silently shows black.
      final handle = await NosmaiLiveKitBridge.registerShareContext();
      _log('Share context: $handle');

      await NosmaiFlutter.initialize(_nosmaiKey);

      final filters = await NosmaiFlutter.instance.getLocalFilters();
      if (!mounted) return;
      setState(() {
        _filters = filters;
        _nosmaiReady = true;
      });
      _log('Nosmai ready — ${filters.length} filter(s)');
    } catch (e) {
      _log('Nosmai init failed: $e');
    }
  }

  /// Publish Nosmai's filtered output. No camera is created here — Nosmai
  /// already owns it via the mounted NosmaiCameraPreview.
  Future<void> _startStreaming() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await NosmaiLiveKitBridge.stopStreaming();
      await _room?.disconnect();
      _room = null;

      // One call: mints the native track and returns it ready to publish.
      _log('Creating Nosmai video track…');
      final track = await NosmaiLiveKitBridge.createVideoTrack();

      // simulcast OFF: each layer needs a differently-scaled copy, and for a
      // TextureBuffer that risks a GPU->CPU conversion per layer — silently
      // reintroducing the readback this path exists to avoid.
      // stopLocalTrackOnUnpublish false: the track's lifetime is Nosmai's, not
      // LiveKit's; letting LiveKit stop it disposes a native object we own.
      final room = Room(
        roomOptions: const RoomOptions(
          stopLocalTrackOnUnpublish: false,
          defaultVideoPublishOptions: VideoPublishOptions(simulcast: false),
        ),
      );
      _room = room;
      await room.connect(_urlCtrl.text.trim(), _tokenCtrl.text.trim());
      await room.localParticipant?.publishVideoTrack(track);

      _publishedTrack = track;
      if (mounted) setState(() => _streaming = true);
      _log('Publishing — check a remote viewer');
    } catch (e) {
      _log('startStreaming error: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Teardown order is load-bearing: stop producing before the consumer goes
  /// away, then leave the room.
  Future<void> _teardown() async {
    try {
      await NosmaiLiveKitBridge.stopStreaming();
    } catch (_) {}
    try {
      await _room?.disconnect();
    } catch (_) {}
    _room = null;
    _publishedTrack = null;
    if (mounted) setState(() => _streaming = false);
  }

  /// Camera switching goes through NOSMAI, never LiveKit — LiveKit does not own
  /// the camera, and its switch APIs would re-run getUserMedia and replace our
  /// track with a raw camera track.
  Future<void> _switchCamera() async {
    await NosmaiFlutter.instance.switchCamera();
    _log('Camera switched');
  }

  Future<void> _applyFilter(NosmaiFilter f) async {
    final ok = await NosmaiFlutter.instance.applyFilter(f.path);
    if (!mounted) return;
    setState(() => _activeFilterPath = ok ? f.path : null);
    _log(ok ? 'Applied ${f.displayName}' : 'Failed ${f.displayName}');
  }

  Future<void> _clearFilters() async {
    await NosmaiFlutter.instance.removeAllFilters();
    if (!mounted) return;
    setState(() => _activeFilterPath = null);
    _log('Filters cleared');
  }

  /// WebRTC's own sender stats — the authoritative numbers.
  ///
  /// The native "pushed N frames" log only says what the bridge HANDED to
  /// WebRTC; it cannot see encoder drops or what actually left the device.
  /// qualityLimitationReason distinguishes "the pipeline is slow" from "the
  /// encoder is throttling on cpu/bandwidth".
  Future<void> _dumpStats() async {
    final track = _publishedTrack;
    if (track == null) {
      _log('stats: not publishing');
      return;
    }
    try {
      final stats = await track.getSenderStats();
      if (stats.isEmpty) {
        _log('stats: none yet (wait a few seconds)');
        return;
      }
      final buf = StringBuffer();
      for (final s in stats) {
        buf.write('${s.frameWidth}x${s.frameHeight} '
            'sent=${s.framesSent} '
            'fps=${s.framesPerSecond?.toStringAsFixed(1) ?? "?"} '
            'limit=${s.qualityLimitationReason ?? "-"}  ');
      }
      _log(buf.toString());
    } catch (e) {
      _log('stats error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Nosmai + LiveKit'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Column(
        children: [
          if (!_streaming) _connectForm(),
          Expanded(
            child: Container(
              color: Colors.black,
              width: double.infinity,
              // NOSMAI owns the preview. This widget is REQUIRED, not cosmetic:
              // it creates the platform view that startProcessing() waits for,
              // and it sets the SDK's current GL view — without which
              // applyFilter fails with "GL preview is unavailable". It must stay
              // mounted for the whole session.
              child: _nosmaiReady
                  ? const NosmaiCameraPreview()
                  : const Center(
                      child: Text('Starting Nosmai…',
                          style: TextStyle(color: Colors.white54)),
                    ),
            ),
          ),
          if (_nosmaiReady) _filterStrip(),
          Container(
            width: double.infinity,
            color: Colors.black87,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(
              _status,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ),
        ],
      ),
      floatingActionButton: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (_streaming) ...[
            FloatingActionButton.extended(
              heroTag: 'rotate',
              onPressed: () async {
                _rotation = (_rotation + 90) % 360;
                await NosmaiLiveKitBridge.setRotation(_rotation);
                _log('rotation -> $_rotation°');
                if (mounted) setState(() {});
              },
              backgroundColor: Colors.teal,
              icon: const Icon(Icons.screen_rotation),
              label: Text('$_rotation°'),
            ),
            const SizedBox(width: 12),
            FloatingActionButton(
              heroTag: 'stats',
              onPressed: _dumpStats,
              backgroundColor: Colors.indigo,
              child: const Icon(Icons.query_stats),
            ),
            const SizedBox(width: 12),
          ],
          FloatingActionButton(
            heroTag: 'switch',
            onPressed: _nosmaiReady ? _switchCamera : null,
            backgroundColor: Colors.white,
            child: const Icon(Icons.cameraswitch, color: Colors.black),
          ),
          const SizedBox(width: 12),
          FloatingActionButton(
            heroTag: 'clear',
            onPressed: _nosmaiReady ? _clearFilters : null,
            backgroundColor: Colors.orange,
            child: const Icon(Icons.filter_none),
          ),
          if (_streaming) ...[
            const SizedBox(width: 12),
            FloatingActionButton(
              heroTag: 'leave',
              onPressed: _teardown,
              backgroundColor: Colors.red,
              child: const Icon(Icons.call_end),
            ),
          ],
        ],
      ),
    );
  }

  Widget _connectForm() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          TextField(
            controller: _urlCtrl,
            decoration: const InputDecoration(
              labelText: 'LiveKit URL',
              helperText: 'LAN IP, not localhost — the phone must reach it',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _tokenCtrl,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'Join token',
              isDense: true,
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: (_busy || !_nosmaiReady) ? null : _startStreaming,
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.bolt),
              label: Text(_busy ? 'Working…' : 'Go live'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterStrip() {
    if (_filters.isEmpty) {
      return const SizedBox(
        height: 60,
        child: Center(
          child: Text('No filters bundled',
              style: TextStyle(color: Colors.white54)),
        ),
      );
    }
    return Container(
      height: 84,
      color: Colors.black,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: _filters.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final f = _filters[i];
          final active = f.path == _activeFilterPath;
          return GestureDetector(
            onTap: () => _applyFilter(f),
            child: Container(
              width: 72,
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: active ? Colors.purpleAccent : Colors.white24,
                  width: active ? 2.5 : 1,
                ),
              ),
              padding: const EdgeInsets.all(4),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    f.filterCategory == NosmaiFilterCategory.effect
                        ? Icons.face_retouching_natural
                        : Icons.auto_awesome,
                    color: active ? Colors.purpleAccent : Colors.white,
                    size: 22,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    f.displayName,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 9,
                      color: active ? Colors.purpleAccent : Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
