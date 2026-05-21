import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:flutter_quick_video_encoder/flutter_quick_video_encoder.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  List<CameraDescription> cameras = [];
  try {
    cameras = await availableCameras();
  } catch (e) {
    if (kDebugMode) {
      print("Error fetching cameras: $e");
    }
  }

  runApp(ReconCameraApp(cameras: cameras));
}

class ReconCameraApp extends StatelessWidget {
  final List<CameraDescription> cameras;
  const ReconCameraApp({super.key, required this.cameras});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RECON-1 Camera',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF030712),
        fontFamily: 'monospace',
      ),
      home: CameraScreen(cameras: cameras),
    );
  }
}

class CameraScreen extends StatefulWidget {
  final List<CameraDescription> cameras;
  const CameraScreen({super.key, required this.cameras});

  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen>
    with WidgetsBindingObserver {
  CameraController? _controller;
  bool _isInitialized = false;
  int _selectedCameraIndex = 0;

  // Configurations
  double _fps = 1.0;
  double _bitrate = 2.5; // Mbps
  bool _useReconPreview =
      false; // true = 1 FPS custom snapshot stream view, false = smooth live preview

  // Dynamic States
  bool _isRecording = false;
  bool _isPaused = false;
  bool _isPlayingPlayback = false;
  List<String> _capturedFrames = [];
  int _playbackIndex = 0;
  String _statusMessage = "ACTIVE. READY TO CAPTURE.";
  bool _isStatusError = false;

  // Timers and Paths
  Timer? _samplingTimer;
  Timer? _playbackTimer;
  Timer? _recordingTimer;
  DateTime? _recordingStartTime;
  Duration _pausedDuration = Duration.zero;
  DateTime? _pauseStartTime;
  String _timerText = "00:00";
  String? _lastCapturedImagePath;
  bool _flashActive = false;

  // Blinking UI pulse helpers
  bool _pulseState = false;
  Timer? _pulseTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeCamera();

    // UI pulse tick for blinking indicators
    _pulseTimer = Timer.periodic(const Duration(milliseconds: 800), (timer) {
      if (mounted) {
        setState(() {
          _pulseState = !_pulseState;
        });
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _samplingTimer?.cancel();
    _playbackTimer?.cancel();
    _recordingTimer?.cancel();
    _pulseTimer?.cancel();
    _controller?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final CameraController? cameraController = _controller;

    if (cameraController == null || !cameraController.value.isInitialized) {
      return;
    }

    if (state == AppLifecycleState.inactive) {
      cameraController.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _initializeCamera();
    }
  }

  Future<void> _initializeCamera() async {
    if (widget.cameras.isEmpty) {
      setState(() {
        _statusMessage = "NO HARDWARE CAMERA DETECTED";
        _isStatusError = true;
      });
      return;
    }

    final cameraDescription = widget.cameras[_selectedCameraIndex];
    final controller = CameraController(
      cameraDescription,
      ResolutionPreset.medium,
      enableAudio: false,
    );

    try {
      await controller.initialize();
      if (mounted) {
        setState(() {
          _controller = controller;
          _isInitialized = true;
          _statusMessage = "ACTIVE. READY TO CAPTURE.";
          _isStatusError = false;
        });
        _restartSampling();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _statusMessage = "INIT ERROR: ${e.toString().toUpperCase()}";
          _isStatusError = true;
        });
      }
    }
  }

  void _restartSampling() {
    _samplingTimer?.cancel();

    // Sample frames periodically based on chosen FPS
    final intervalMs = (1000 / _fps).round();
    _samplingTimer = Timer.periodic(Duration(milliseconds: intervalMs), (
      timer,
    ) {
      if (_isInitialized &&
          _controller != null &&
          !_isPlayingPlayback &&
          !_isPaused) {
        _captureFrame();
      }
    });
  }

  Future<void> _captureFrame() async {
    if (_controller == null || !_controller!.value.isInitialized) return;

    try {
      final image = await _controller!.takePicture();

      if (!mounted) return;

      setState(() {
        _lastCapturedImagePath = image.path;
        _flashActive = true;

        if (_isRecording) {
          _capturedFrames.add(image.path);
        }
      });

      // Quick visual shutter flash effect
      Future.delayed(const Duration(milliseconds: 80), () {
        if (mounted) {
          setState(() {
            _flashActive = false;
          });
        }
      });
    } catch (e) {
      if (kDebugMode) {
        print("Frame capture tick error: $e");
      }
    }
  }

  void _startRecording() {
    if (!_isInitialized) return;

    setState(() {
      _isRecording = true;
      _isPlayingPlayback = false;
      _capturedFrames.clear();
      _recordingStartTime = DateTime.now();
      _timerText = "00:00";
      _statusMessage = "CAPTURING LOW-FPS VIDEO STREAM...";
    });

    _recordingTimer?.cancel();
    _recordingTimer = Timer.periodic(const Duration(milliseconds: 100), (
      timer,
    ) {
      if (_recordingStartTime != null && mounted) {
        final elapsed =
            DateTime.now().difference(_recordingStartTime!) - _pausedDuration;
        final minutes = elapsed.inMinutes.toString().padLeft(2, '0');
        final seconds = (elapsed.inSeconds % 60).toString().padLeft(2, '0');
        setState(() {
          _timerText = "$minutes:$seconds";
        });
      }
    });

    // Make sure dynamic sampling updates frames precisely to the list
    _restartSampling();
  }

  void _togglePause() {
    if (!_isRecording) return;

    setState(() {
      _isPaused = !_isPaused;
      if (_isPaused) {
        _pauseStartTime = DateTime.now();
        _statusMessage = "RECORDING PAUSED";
        _samplingTimer?.cancel();
      } else {
        _pausedDuration += DateTime.now().difference(_pauseStartTime!);
        _statusMessage = "CAPTURING LOW-FPS VIDEO STREAM...";
        _restartSampling();
      }
    });
  }

  void _stopRecording() {
    if (!_isRecording) return;

    _recordingTimer?.cancel();
    _samplingTimer?.cancel();
    setState(() {
      _isRecording = false;
      _isPaused = false;
      _pausedDuration = Duration.zero;
      _pauseStartTime = null;
      _statusMessage =
          "RECORDING STOPPED. ${_capturedFrames.length} FRAMES SAVED.";
    });
  }

  void _startPlayback() {
    if (_capturedFrames.isEmpty) return;

    _playbackTimer?.cancel();
    setState(() {
      _isPlayingPlayback = true;
      _playbackIndex = 0;
      _statusMessage = "PLAYING BACK CAPTURED TIMELAPSE SEQUENCE";
    });

    final intervalMs = (1000 / _fps).round();
    _playbackTimer = Timer.periodic(Duration(milliseconds: intervalMs), (
      timer,
    ) {
      if (mounted) {
        setState(() {
          if (_playbackIndex < _capturedFrames.length - 1) {
            _playbackIndex++;
          } else {
            _playbackIndex = 0; // Loop playback
          }
        });
      }
    });
  }

  void _stopPlayback() {
    _playbackTimer?.cancel();
    setState(() {
      _isPlayingPlayback = false;
      _statusMessage = "ACTIVE. READY TO CAPTURE.";
    });
  }

  Future<void> _exportSequence() async {
    if (_capturedFrames.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No frames recorded to export.')),
      );
      return;
    }

    setState(() {
      _statusMessage = "PREPARING EXPORT...";
    });

    try {
      // Decode first frame to determine video dimensions
      final firstBytes = await File(_capturedFrames[0]).readAsBytes();
      final Completer<ui.Image> firstCompleter = Completer();
      ui.decodeImageFromList(
        firstBytes,
        (ui.Image img) => firstCompleter.complete(img),
      );
      final firstImage = await firstCompleter.future;
      final int frameWidth = firstImage.width;
      final int frameHeight = firstImage.height;

      final tempDir = await getTemporaryDirectory();
      final outputVideoPath =
          '${tempDir.path}/recon1_timelapse_${DateTime.now().millisecondsSinceEpoch}.mp4';

      setState(() {
        _statusMessage = "ENCODING LOW-FPS MP4 VIDEO...";
      });

      await FlutterQuickVideoEncoder.setup(
        width: frameWidth,
        height: frameHeight,
        fps: _fps.round(),
        videoBitrate: (_bitrate * 1000000).round(),
        profileLevel: ProfileLevel.any,
        audioChannels: 0,
        audioBitrate: 0,
        sampleRate: 0,
        filepath: outputVideoPath,
      );

      for (int i = 0; i < _capturedFrames.length; i++) {
        setState(() {
          _statusMessage =
              "ENCODING FRAME ${i + 1}/${_capturedFrames.length}...";
        });

        final file = File(_capturedFrames[i]);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          final Completer<ui.Image> completer = Completer();
          ui.decodeImageFromList(
            bytes,
            (ui.Image img) => completer.complete(img),
          );
          final image = await completer.future;
          final byteData = await image.toByteData(
            format: ui.ImageByteFormat.rawRgba,
          );
          if (byteData != null) {
            await FlutterQuickVideoEncoder.appendVideoFrame(
              byteData.buffer.asUint8List(),
            );
          }
        }
      }

      await FlutterQuickVideoEncoder.finish();

      setState(() {
        _statusMessage = "VIDEO COMPILED. LAUNCHING EXPORT SHARE SHEET...";
      });

      await Share.shareXFiles([
        XFile(outputVideoPath),
      ], text: 'RECON-1 Custom Video Time-lapse (${_fps.round()} FPS)');

      setState(() {
        _statusMessage = "EXPORT COMPLETED SUCCESSFULLY.";
        _isStatusError = false;
      });
    } catch (e) {
      setState(() {
        _statusMessage = "EXPORT FAILED: $e";
        _isStatusError = true;
      });
    }
  }

  void _toggleCamera() {
    if (widget.cameras.length < 2) return;
    setState(() {
      _isInitialized = false;
      _selectedCameraIndex = (_selectedCameraIndex + 1) % widget.cameras.length;
    });
    _initializeCamera();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isPortrait = size.height > size.width;

    return Scaffold(
      body: SafeArea(
        child: Container(
          decoration: const BoxDecoration(
            gradient: RadialGradient(
              center: Alignment.topCenter,
              radius: 1.5,
              colors: [Color(0xFF111827), Color(0xFF030712)],
            ),
          ),
          child: Column(
            children: [
              // 1. Sleek Technical Header Bar
              _buildHeader(),

              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16.0,
                    vertical: 8.0,
                  ),
                  child: Center(
                    child: Container(
                      constraints: const BoxConstraints(maxWidth: 800),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // 3. Main Camera Viewport Console
                          _buildViewport(isPortrait),
                          const SizedBox(height: 16),

                          // 4. Tech Action Console Buttons
                          _buildActionConsole(),
                          const SizedBox(height: 24),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    // Determine status colors based on states
    Color dotColor = const Color(0xFF10B981); // Emerald
    String statusTitle = "LIVE PREVIEW";
    Color titleColor = const Color(0xFF94A3B8);

    if (_isStatusError) {
      dotColor = const Color(0xFFEF4444); // Coral Red
      statusTitle = "SYSTEM ERROR";
      titleColor = const Color(0xFFEF4444);
    } else if (_isPlayingPlayback) {
      dotColor = const Color(0xFF6366F1); // Indigo
      statusTitle = "PLAYBACK MON";
      titleColor = const Color(0xFF6366F1);
    } else if (_isRecording) {
      dotColor = const Color(0xFFEF4444); // Coral Red
      statusTitle = "RECORDING ACTIVE";
      titleColor = const Color(0xFFEF4444);
    }

    final showDot = !_isRecording || _pulseState; // blink when recording

    return Container(
      margin: const EdgeInsets.all(16.0),
      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 16.0),
      decoration: BoxDecoration(
        color: const Color(0xFF111827).withOpacity(0.6),
        borderRadius: BorderRadius.circular(16.0),
        border: Border.all(color: Colors.white.withOpacity(0.08)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8.0),
                decoration: BoxDecoration(
                  color: const Color(0xFF6366F1).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8.0),
                ),
                child: const Icon(
                  Icons.videocam,
                  color: Color(0xFF6366F1),
                  size: 20,
                ),
              ),
              const SizedBox(width: 12),
            ],
          ),

          // System Status Dot & Label
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: 14.0,
              vertical: 6.0,
            ),
            decoration: BoxDecoration(
              color: Colors.black.withOpacity(0.4),
              borderRadius: BorderRadius.circular(99),
              border: Border.all(color: Colors.white.withOpacity(0.04)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: showDot ? dotColor : Colors.transparent,
                    shape: BoxShape.circle,
                    boxShadow: showDot
                        ? [
                            BoxShadow(
                              color: dotColor,
                              blurRadius: 8,
                              spreadRadius: 1,
                            ),
                          ]
                        : [],
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  statusTitle,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0,
                    color: titleColor,
                  ),
                ),
              ],
            ),
          ),

          // Settings Button
          GestureDetector(
            onTap: _showSettingsPanel,
            child: Container(
              padding: const EdgeInsets.all(10.0),
              decoration: BoxDecoration(
                color: Colors.black.withOpacity(0.3),
                borderRadius: BorderRadius.circular(8.0),
              ),
              child: const Icon(
                Icons.settings,
                color: Color(0xFF94A3B8),
                size: 20,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showSettingsPanel() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => Container(
        decoration: BoxDecoration(
          color: const Color(0xFF111827),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border.all(color: Colors.white.withOpacity(0.08)),
        ),
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
          top: 24,
          left: 20,
          right: 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              "SETTINGS",
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w800,
                color: Colors.white,
                letterSpacing: 1.2,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            _buildSettingsToolbar(true),
            const SizedBox(height: 24),
            TextButton(
              onPressed: () => Navigator.pop(context),
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                backgroundColor: const Color(0xFF6366F1).withOpacity(0.1),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              child: const Text(
                "CLOSE",
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF6366F1),
                  letterSpacing: 1.0,
                ),
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingsToolbar(bool isPortrait) {
    final toolbarContent = [
      // FPS Config
      Expanded(
        flex: isPortrait ? 0 : 1,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  "SPEED (FPS)",
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF94A3B8),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF6366F1).withOpacity(0.1),
                    border: Border.all(
                      color: const Color(0xFF6366F1).withOpacity(0.2),
                    ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    "${_fps.round()}",
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF6366F1),
                    ),
                  ),
                ),
              ],
            ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: const Color(0xFF6366F1),
                inactiveTrackColor: Colors.black.withOpacity(0.5),
                thumbColor: Colors.white,
                overlayColor: const Color(0xFF6366F1).withOpacity(0.2),
                trackHeight: 4,
              ),
              child: Slider(
                min: 1.0,
                max: 30.0,
                value: _fps,
                divisions: 29,
                onChanged: _isRecording || _isPlayingPlayback
                    ? null
                    : (val) {
                        setState(() {
                          _fps = val;
                        });
                        _restartSampling();
                      },
              ),
            ),
          ],
        ),
      ),
      if (isPortrait) const SizedBox(height: 16) else const SizedBox(width: 24),

      // Bitrate Config
      Expanded(
        flex: isPortrait ? 0 : 1,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  "BITRATE",
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF94A3B8),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF6366F1).withOpacity(0.1),
                    border: Border.all(
                      color: const Color(0xFF6366F1).withOpacity(0.2),
                    ),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    "${_bitrate.toStringAsFixed(1)} Mbps",
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      color: Color(0xFF6366F1),
                    ),
                  ),
                ),
              ],
            ),
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: const Color(0xFF6366F1),
                inactiveTrackColor: Colors.black.withOpacity(0.5),
                thumbColor: Colors.white,
                overlayColor: const Color(0xFF6366F1).withOpacity(0.2),
                trackHeight: 4,
              ),
              child: Slider(
                min: 0.5,
                max: 10.0,
                value: _bitrate,
                divisions: 19,
                onChanged: _isRecording
                    ? null
                    : (val) {
                        setState(() {
                          _bitrate = val;
                        });
                      },
              ),
            ),
          ],
        ),
      ),
      if (isPortrait) const SizedBox(height: 16) else const SizedBox(width: 24),

      // Viewfinder Mode Toggle
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            "PREVIEW ENGINE",
            style: TextStyle(
              fontSize: 9,
              fontWeight: FontWeight.bold,
              color: Color(0xFF94A3B8),
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildToggleButton(
                label: "LIVE",
                isSelected: !_useReconPreview,
                onPressed: () {
                  setState(() {
                    _useReconPreview = false;
                  });
                },
              ),
              _buildToggleButton(
                label: "RECON 1-FPS",
                isSelected: _useReconPreview,
                onPressed: () {
                  setState(() {
                    _useReconPreview = true;
                  });
                },
              ),
            ],
          ),
        ],
      ),
    ];

    return ClipRRect(
      borderRadius: BorderRadius.circular(24.0),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
        child: Container(
          padding: const EdgeInsets.all(20.0),
          decoration: BoxDecoration(
            color: const Color(0xFF111827).withOpacity(0.4),
            borderRadius: BorderRadius.circular(24.0),
            border: Border.all(color: Colors.white.withOpacity(0.08)),
          ),
          child: isPortrait
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: toolbarContent,
                )
              : Row(children: toolbarContent),
        ),
      ),
    );
  }

  Widget _buildToggleButton({
    required String label,
    required bool isSelected,
    required VoidCallback onPressed,
  }) {
    return GestureDetector(
      onTap: onPressed,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF6366F1)
              : Colors.black.withOpacity(0.4),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected
                ? const Color(0xFF6366F1)
                : Colors.white.withOpacity(0.05),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w900,
            color: isSelected ? Colors.white : const Color(0xFF94A3B8),
            letterSpacing: 0.5,
          ),
        ),
      ),
    );
  }

  Widget _buildViewport(bool isPortrait) {
    // 3:4 aspect ratio for portrait view, 16:9 for landscape
    final double aspectRatio = isPortrait ? (3 / 4) : (16 / 9);

    return Container(
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(24.0),
        border: Border.all(
          color: _isRecording
              ? const Color(0xFFEF4444)
              : Colors.white.withOpacity(0.08),
          width: _isRecording ? 2.0 : 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: _isRecording
                ? const Color(0xFFEF4444).withOpacity(0.15)
                : Colors.black.withOpacity(0.4),
            blurRadius: _isRecording ? 24.0 : 16.0,
            spreadRadius: _isRecording ? 2.0 : 0.0,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(22.0),
        child: AspectRatio(
          aspectRatio: aspectRatio,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 1. Raw Preview feed / Recon snapshot feed / Playback feed
              _buildViewfinderFeed(isPortrait),

              // 2. Cyberpunk Crosshair Reticle Watermark
              Center(
                child: Opacity(
                  opacity: 0.15,
                  child: Container(
                    width: 64,
                    height: 64,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withOpacity(0.3),
                        width: 1,
                      ),
                    ),
                    child: const Center(
                      child: Icon(Icons.add, color: Colors.white, size: 16),
                    ),
                  ),
                ),
              ),

              // 3. Floating HUD Indicator Tags
              _buildHUDOverlay(),

              // 4. Visual Shutter Flash Overlay
              AnimatedOpacity(
                opacity: _flashActive ? 0.7 : 0.0,
                duration: const Duration(milliseconds: 20),
                child: Container(color: Colors.white),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildViewfinderFeed(bool isPortrait) {
    if (_isPlayingPlayback) {
      if (_capturedFrames.isEmpty) return const SizedBox();
      return Image.file(
        File(_capturedFrames[_playbackIndex]),
        fit: isPortrait ? BoxFit.cover : BoxFit.contain,
      );
    }

    if (!_isInitialized || _controller == null) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF6366F1)),
      );
    }

    // Determine preview widget based on Mode Toggle
    if (_useReconPreview && _lastCapturedImagePath != null) {
      return Image.file(
        File(_lastCapturedImagePath!),
        fit: isPortrait ? BoxFit.cover : BoxFit.contain,
      );
    }

    // Default smooth preview with scaling to avoid stretching
    return Transform.scale(
      scale: 1.0,
      child: Center(child: CameraPreview(_controller!)),
    );
  }

  Widget _buildHUDOverlay() {
    String fpsTag = "${_fps.round()} FPS";
    String resolutionTag = "-- x --";
    if (_isInitialized && _controller != null) {
      final res = _controller!.value.previewSize;
      if (res != null) {
        resolutionTag =
            "${res.height.round()} x ${res.width.round()}"; // flipped for portrait matching
      }
    }

    return Stack(
      children: [
        // Top Left Status Tags
        Positioned(
          top: 14,
          left: 14,
          child: Row(
            children: [
              if (!_isRecording && !_isPlayingPlayback)
                _buildHUDTag(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: const BoxDecoration(
                          color: Color(0xFF10B981),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      const Text(
                        "LIVE",
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              if (_isRecording)
                _buildHUDTag(
                  backgroundColor: const Color(0xFFEF4444).withOpacity(0.2),
                  borderColor: const Color(0xFFEF4444).withOpacity(0.4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: _isPaused
                              ? const Color(0xFFF59E0B)
                              : (_pulseState
                                    ? const Color(0xFFEF4444)
                                    : Colors.transparent),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _isPaused ? "PAUSED" : "REC",
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color: _isPaused
                              ? const Color(0xFFF59E0B)
                              : const Color(0xFFEF4444),
                        ),
                      ),
                    ],
                  ),
                ),
              if (_isPlayingPlayback)
                _buildHUDTag(
                  backgroundColor: const Color(0xFF6366F1).withOpacity(0.2),
                  borderColor: const Color(0xFF6366F1).withOpacity(0.4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: const BoxDecoration(
                          color: Color(0xFF6366F1),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        "PLAYBACK (${_playbackIndex + 1}/${_capturedFrames.length})",
                        style: const TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF6366F1),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),

        // Top Right Chrono Timer Tag
        if (_isRecording)
          Positioned(
            top: 14,
            right: 14,
            child: _buildHUDTag(
              backgroundColor: const Color(0xFFEF4444).withOpacity(0.15),
              borderColor: const Color(0xFFEF4444).withOpacity(0.3),
              child: Text(
                _timerText,
                style: const TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFFEF4444),
                ),
              ),
            ),
          ),

        // Bottom Left Tech Spec Tags
        Positioned(
          bottom: 14,
          left: 14,
          child: Row(
            children: [
              _buildHUDTag(
                child: Text(
                  resolutionTag,
                  style: const TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              _buildHUDTag(
                child: Text(
                  fpsTag,
                  style: const TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
        ),

        // Dynamic Quick Camera Switcher Trigger
        if (widget.cameras.length > 1 && !_isRecording && !_isPlayingPlayback)
          Positioned(
            bottom: 14,
            right: 14,
            child: GestureDetector(
              onTap: _toggleCamera,
              child: _buildHUDTag(
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.flip_camera_ios, size: 10, color: Colors.white),
                    SizedBox(width: 4),
                    Text(
                      "FLIP",
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildHUDTag({
    required Widget child,
    Color? backgroundColor,
    Color? borderColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10.0, vertical: 5.0),
      decoration: BoxDecoration(
        color: backgroundColor ?? Colors.black.withOpacity(0.7),
        border: Border.all(color: borderColor ?? Colors.white.withOpacity(0.1)),
        borderRadius: BorderRadius.circular(8.0),
      ),
      child: child,
    );
  }

  Widget _buildActionConsole() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Real-time Console Terminal Output Message
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.5),
            border: Border.all(color: Colors.white.withOpacity(0.04)),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              const Text(
                "> SYS_LOG:",
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.w900,
                  color: Color(0xFF64748B),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _statusMessage,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    color: _isStatusError
                        ? const Color(0xFFEF4444)
                        : Colors.white.withOpacity(0.9),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Grid Actions (Initiate, Halt, Export, Playback)
        Row(
          children: [
            // Recording Toggle Button
            Expanded(
              flex: _isRecording ? 1 : 2,
              child: _buildConsoleButton(
                icon: _isRecording ? Icons.square : Icons.circle,
                label: _isRecording ? "HALT" : "INITIATE RECORD",
                color: _isRecording
                    ? const Color(0xFFEF4444)
                    : const Color(0xFF6366F1),
                isRecordingButton: true,
                onPressed: _isPlayingPlayback
                    ? null
                    : () {
                        if (_isRecording) {
                          _stopRecording();
                        } else {
                          _startRecording();
                        }
                      },
              ),
            ),
            if (_isRecording) const SizedBox(width: 10),

            // Pause Button
            if (_isRecording)
              Expanded(
                flex: 1,
                child: _buildConsoleButton(
                  icon: _isPaused ? Icons.play_arrow : Icons.pause,
                  label: _isPaused ? "RESUME" : "PAUSE",
                  color: const Color(0xFFF59E0B),
                  outline: true,
                  onPressed: _togglePause,
                ),
              ),
            if (_isRecording) const SizedBox(width: 10),

            // Playback Toggle Button
            Expanded(
              flex: 1,
              child: _buildConsoleButton(
                icon: _isPlayingPlayback ? Icons.stop : Icons.play_arrow,
                label: _isPlayingPlayback ? "STOP PREV" : "PLAY TIMELAPSE",
                color: const Color(0xFF6366F1),
                outline: true,
                disabled: _isRecording || _capturedFrames.isEmpty,
                onPressed: () {
                  if (_isPlayingPlayback) {
                    _stopPlayback();
                  } else {
                    _startPlayback();
                  }
                },
              ),
            ),
            const SizedBox(width: 10),

            // Export Button
            Expanded(
              flex: 1,
              child: _buildConsoleButton(
                icon: Icons.share,
                label: "EXPORT SEQUENCE",
                color: const Color(0xFF10B981),
                outline: true,
                disabled:
                    _isRecording ||
                    _isPlayingPlayback ||
                    _capturedFrames.isEmpty,
                onPressed: _exportSequence,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildConsoleButton({
    required IconData icon,
    required String label,
    required Color color,
    bool outline = false,
    bool disabled = false,
    bool isRecordingButton = false,
    required VoidCallback? onPressed,
  }) {
    final bool isRealDisabled = disabled || onPressed == null;

    Color bg;
    Color fg;
    Border? border;

    if (isRealDisabled) {
      bg = Colors.white.withOpacity(0.02);
      fg = const Color(0xFF64748B);
      border = Border.all(color: Colors.white.withOpacity(0.04));
    } else if (outline) {
      bg = color.withOpacity(0.05);
      fg = color;
      border = Border.all(color: color.withOpacity(0.3));
    } else {
      bg = color;
      fg = Colors.white;
      border = null;
    }

    return Container(
      height: 52,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(14),
        border: border,
        boxShadow: !isRealDisabled && !outline && !isRecordingButton
            ? [
                BoxShadow(
                  color: color.withOpacity(0.2),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ]
            : [],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onPressed,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: fg, size: isRecordingButton ? 20 : 16),
                const SizedBox(height: 3),
                Text(
                  label.toUpperCase(),
                  style: TextStyle(
                    fontSize: 8,
                    fontWeight: FontWeight.w900,
                    color: fg,
                    letterSpacing: 0.5,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
