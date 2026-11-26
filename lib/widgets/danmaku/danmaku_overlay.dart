import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:provider/provider.dart';

import '../../media/media_item.dart';
import '../../mpv/mpv.dart';
import '../../providers/multi_server_provider.dart';
import '../../services/danmaku/danmaku_controller.dart';
import '../../services/pip_service.dart';
import 'danmaku_engine.dart';
import 'danmaku_painter.dart';

/// Non-interactive transparent danmaku overlay synchronized with [Player] clock
/// via vsync frame interpolation, inspired by NipaPlay-Reload's Next overlay.
class DanmakuOverlay extends StatefulWidget {
  final Player player;
  final DanmakuController controller;
  final MediaItem metadata;
  final String? activeFilePath;

  const DanmakuOverlay({
    super.key,
    required this.player,
    required this.controller,
    required this.metadata,
    this.activeFilePath,
  });

  @override
  State<DanmakuOverlay> createState() => _DanmakuOverlayState();
}

class _DanmakuOverlayState extends State<DanmakuOverlay> with SingleTickerProviderStateMixin {
  final DanmakuLayoutEngine _engine = DanmakuLayoutEngine();
  late final ValueNotifier<double> _smoothTimeSec;
  late final Ticker _ticker;

  Duration? _lastTickElapsed;
  bool _isPlaying = false;
  bool _isBuffering = false;
  double _rate = 1.0;

  StreamSubscription<Duration>? _posSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<bool>? _bufferingSub;
  StreamSubscription<double>? _rateSub;
  StreamSubscription<Duration?>? _jumpSub;

  @override
  void initState() {
    super.initState();
    _smoothTimeSec = ValueNotifier<double>(widget.player.state.position.inMilliseconds / 1000.0);
    _isPlaying = widget.player.state.playing;
    _isBuffering = widget.player.state.buffering;
    _rate = widget.player.state.rate;

    _ticker = createTicker(_onTick);
    widget.controller.addListener(_onControllerChanged);
    PipService().isPipActive.addListener(_onPipChanged);

    _bindPlayerStreams(widget.player);
    _syncCommentsToEngine();
    _syncItem();
    _updateTickerState();
  }

  @override
  void didUpdateWidget(covariant DanmakuOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onControllerChanged);
      widget.controller.addListener(_onControllerChanged);
      _syncCommentsToEngine();
    }
    if (oldWidget.player != widget.player) {
      _cancelPlayerStreams();
      _smoothTimeSec.value = widget.player.state.position.inMilliseconds / 1000.0;
      _isPlaying = widget.player.state.playing;
      _isBuffering = widget.player.state.buffering;
      _rate = widget.player.state.rate;
      _bindPlayerStreams(widget.player);
    }
    if (oldWidget.metadata != widget.metadata || oldWidget.activeFilePath != widget.activeFilePath) {
      _syncItem();
    }
    _updateTickerState();
  }

  void _syncItem() {
    MultiServerProvider? multiServer;
    try {
      multiServer = context.read<MultiServerProvider?>();
    } catch (_) {
      multiServer = null;
    }
    widget.controller.syncForItem(
      metadata: widget.metadata,
      activeFilePath: widget.activeFilePath,
      multiServer: multiServer,
    );
  }

  void _bindPlayerStreams(Player player) {
    _posSub = player.streams.position.listen((pos) {
      final mpvSec = pos.inMilliseconds / 1000.0;
      final diff = mpvSec - _smoothTimeSec.value;
      if (!_isPlaying || _isBuffering || diff.abs() > 0.35) {
        _smoothTimeSec.value = mpvSec;
      } else if (diff.abs() > 0.06) {
        _smoothTimeSec.value += diff * 0.25;
      }
    });
    _playingSub = player.streams.playing.listen((playing) {
      if (_isPlaying == playing) return;
      _isPlaying = playing;
      if (!playing) {
        _smoothTimeSec.value = widget.player.state.position.inMilliseconds / 1000.0;
      }
      _updateTickerState();
    });
    _bufferingSub = player.streams.buffering.listen((buffering) {
      if (_isBuffering == buffering) return;
      _isBuffering = buffering;
      _updateTickerState();
    });
    _rateSub = player.streams.rate.listen((rate) {
      _rate = rate > 0 ? rate : 1.0;
    });
    _jumpSub = player.streams.playheadJump.listen((target) {
      if (target != null) {
        _smoothTimeSec.value = target.inMilliseconds / 1000.0;
      }
    });
  }

  void _cancelPlayerStreams() {
    _posSub?.cancel();
    _playingSub?.cancel();
    _bufferingSub?.cancel();
    _rateSub?.cancel();
    _jumpSub?.cancel();
    _posSub = null;
    _playingSub = null;
    _bufferingSub = null;
    _rateSub = null;
    _jumpSub = null;
  }

  void _onControllerChanged() {
    _syncCommentsToEngine();
    _updateTickerState();
    if (mounted) setState(() {});
  }

  void _onPipChanged() {
    _updateTickerState();
    if (mounted) setState(() {});
  }

  void _syncCommentsToEngine() {
    _engine.setComments(widget.controller.processedComments, widget.controller.commentsVersion);
  }

  void _updateTickerState() {
    final shouldTick =
        widget.controller.enabled &&
        _isPlaying &&
        !_isBuffering &&
        !PipService().isPipActive.value &&
        widget.controller.processedComments.isNotEmpty;

    if (shouldTick) {
      if (!_ticker.isActive) {
        _lastTickElapsed = null;
        _ticker.start();
      }
    } else if (_ticker.isActive) {
      _ticker.stop();
      _lastTickElapsed = null;
    }
  }

  void _onTick(Duration elapsed) {
    final prev = _lastTickElapsed;
    _lastTickElapsed = elapsed;
    if (prev == null) return;
    final dtSec = (elapsed - prev).inMicroseconds / 1000000.0;
    if (dtSec <= 0 || dtSec > 0.5) return;
    _smoothTimeSec.value += dtSec * _rate;
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    PipService().isPipActive.removeListener(_onPipChanged);
    _cancelPlayerStreams();
    _ticker.dispose();
    _smoothTimeSec.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.controller.enabled || PipService().isPipActive.value) {
      return const SizedBox.shrink();
    }
    return IgnorePointer(
      child: ExcludeFocus(
        child: RepaintBoundary(
          child: LayoutBuilder(
            builder: (context, constraints) {
              return CustomPaint(
                size: constraints.biggest,
                painter: DanmakuCanvasPainter(
                  smoothTimeSec: _smoothTimeSec,
                  engine: _engine,
                  settings: widget.controller.settings,
                  commentsVersion: widget.controller.commentsVersion,
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
