import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter/services.dart';

import '../../../focus/dpad_navigator.dart';
import '../../../library/local_library_client.dart';
import '../../../mpv/mpv.dart';
import '../../../media/media_source_info.dart';
import '../../../media/media_version.dart';
import '../../../services/sleep_timer_service.dart';
import '../../../utils/platform_detector.dart';
import '../../../utils/quality_preset_labels.dart';
import '../../../i18n/strings.g.dart';
import '../../../widgets/overlay_sheet.dart';
import '../../danmaku/danmaku_badge_icon.dart';
import '../models/track_controls_state.dart';
import '../sheets/base_video_control_sheet.dart';
import '../sheets/chapter_sheet.dart';
import '../sheets/danmaku_sheet.dart';
import '../sheets/queue_sheet.dart';
import '../sheets/track_sheet.dart';
import '../sheets/version_quality_sheet.dart';
import '../sheets/video_settings_sheet.dart';
import '../../../utils/track_label_builder.dart';
import '../video_control_button.dart';

/// Row of track and chapter control buttons for the video player
class TrackChapterControls extends StatelessWidget {
  final Player player;
  final List<MediaChapter> chapters;
  final bool chaptersLoaded;
  final TrackControlsState trackControlsState;
  final Future<void> Function(Duration position)? onSeekRequested;
  final Function(Duration position)? onSeekCompleted;

  /// List of FocusNodes for the buttons (passed from parent for navigation)
  final List<FocusNode>? focusNodes;

  /// Called when focus changes on any button
  final ValueChanged<bool>? onFocusChange;

  final VoidCallback? onNavigateLeft;

  /// Called to navigate up from any button (e.g., to focus timeline on TV)
  final VoidCallback? onNavigateUp;

  /// Called to navigate down from any button (e.g., to show content strip on TV)
  final VoidCallback? onNavigateDown;

  /// Whether to hide the chapters and queue buttons (mobile uses content strip instead)
  final bool hideChaptersAndQueue;

  const TrackChapterControls({
    super.key,
    required this.player,
    required this.chapters,
    required this.chaptersLoaded,
    required this.trackControlsState,
    this.onSeekRequested,
    this.onSeekCompleted,
    this.focusNodes,
    this.onFocusChange,
    this.onNavigateLeft,
    this.onNavigateUp,
    this.onNavigateDown,
    this.hideChaptersAndQueue = false,
  });

  KeyEventResult _handleButtonKeyEvent(FocusNode _, KeyEvent event, int index, int totalButtons) {
    if (!event.isActionable) {
      return KeyEventResult.ignored;
    }

    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.arrowLeft) {
      if (index > 0 && focusNodes != null && focusNodes!.length > index - 1) {
        focusNodes![index - 1].requestFocus();
        return KeyEventResult.handled;
      } else if (index == 0) {
        onNavigateLeft?.call();
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowRight) {
      if (index < totalButtons - 1 && focusNodes != null && focusNodes!.length > index + 1) {
        focusNodes![index + 1].requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowUp) {
      onNavigateUp?.call();
      return KeyEventResult.handled;
    }

    if (key == LogicalKeyboardKey.arrowDown) {
      onNavigateDown?.call();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  /// Build a track control button with consistent focus handling
  Widget _buildTrackButton({
    required int buttonIndex,
    required String semanticLabel,
    required VoidCallback? onPressed,
    required int Function() getTotalButtons,
    IconData? icon,
    Widget Function(BuildContext context, Color iconColor)? iconBuilder,
    Color? color,
    double iconSize = 24,
    double iconFill = 1,
    double? iconWeight = 700,
    bool pillSurface = false,
    BoxConstraints? constraints,
    EdgeInsetsGeometry? padding,
    BorderRadius? focusBorderRadius,
    String? tooltip,
    String? label,
    String? semanticValue,
    bool? checked,
    bool isActive = false,
  }) {
    return VideoControlButton(
      icon: icon,
      iconBuilder: iconBuilder,
      color: color,
      iconSize: iconSize,
      iconFill: iconFill,
      iconWeight: iconWeight,
      pillSurface: pillSurface,
      constraints: constraints,
      padding: padding,
      focusBorderRadius: focusBorderRadius,
      tooltip: tooltip,
      label: label,
      semanticLabel: semanticLabel,
      semanticValue: semanticValue,
      checked: checked,
      isActive: isActive,
      focusNode: focusNodes != null && focusNodes!.length > buttonIndex ? focusNodes![buttonIndex] : null,
      onKeyEvent: focusNodes != null
          ? (node, event) => _handleButtonKeyEvent(node, event, buttonIndex, getTotalButtons())
          : null,
      onFocusChange: onFocusChange,
      onPressed: onPressed,
    );
  }

  Widget _buildGroupDivider(bool isMobile) {
    return Center(
      child: Container(
        width: 1,
        height: 16,
        margin: EdgeInsets.symmetric(horizontal: isMobile ? 2 : 4),
        color: Colors.white.withValues(alpha: 0.16),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<Tracks>(
      stream: player.streams.tracks,
      initialData: player.state.tracks,
      builder: (context, snapshot) {
        final tracks = snapshot.data;
        final state = trackControlsState;
        final isMobile = PlatformDetector.isMobile(context);
        final isDesktop = PlatformDetector.isDesktopOS();

        final contentGroup = <Widget>[];
        final settingsGroup = <Widget>[];
        final windowGroup = <Widget>[];
        int totalFocusable = 0;
        final showText = !isMobile && MediaQuery.sizeOf(context).width >= 850;

        final danmakuController = state.danmakuController;
        if (state.danmakuSupported && danmakuController != null) {
          final toggleIndex = totalFocusable++;
          final settingsIndex = totalFocusable++;
          contentGroup.add(
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 4),
                child: Container(
                  height: 32,
                  padding: const EdgeInsets.symmetric(horizontal: 3),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      ListenableBuilder(
                        listenable: danmakuController,
                        builder: (context, _) {
                          final enabled = danmakuController.enabled;
                          return _buildTrackButton(
                            buttonIndex: toggleIndex,
                            iconBuilder: (_, color) => DanmakuBadgeIcon(enabled: enabled, color: color, size: 22),
                            color: enabled ? null : Colors.white.withValues(alpha: 0.85),
                            isActive: enabled,
                            checked: enabled,
                            tooltip: enabled ? t.danmaku.toggleOff : t.danmaku.toggleOn,
                            semanticLabel: enabled ? t.danmaku.toggleOff : t.danmaku.toggleOn,
                            constraints: const BoxConstraints(minWidth: 34, minHeight: 28),
                            padding: EdgeInsets.zero,
                            focusBorderRadius: const BorderRadius.all(Radius.circular(14)),
                            getTotalButtons: () => totalFocusable,
                            onPressed: () => danmakuController.toggleEnabled(),
                          );
                        },
                      ),
                      Container(width: 1, height: 14, color: Colors.white.withValues(alpha: 0.18)),
                      _buildTrackButton(
                        buttonIndex: settingsIndex,
                        icon: Symbols.tune_rounded,
                        iconSize: 20,
                        iconFill: 1,
                        iconWeight: 700,
                        tooltip: t.danmaku.settings,
                        semanticLabel: t.danmaku.settings,
                        constraints: const BoxConstraints(minWidth: 32, minHeight: 28),
                        padding: EdgeInsets.zero,
                        focusBorderRadius: const BorderRadius.all(Radius.circular(14)),
                        getTotalButtons: () => totalFocusable,
                        onPressed: () {
                          state.onCancelAutoHide?.call();
                          OverlaySheetController.of(context)
                              .show(builder: (_) => DanmakuSheet(controller: danmakuController))
                              .whenComplete(() => state.onStartAutoHide?.call());
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }

        if (state.serverId == LocalLibraryClient.localServerId &&
            state.availableVersions.length > 1 &&
            state.onSwitchVersion != null) {
          contentGroup.add(
            _buildTrackButton(
              buttonIndex: totalFocusable++,
              icon: Symbols.video_file_rounded,
              iconSize: 24,
              iconFill: 1,
              iconWeight: 700,
              label: showText ? t.videoControls.versionColumnHeader : null,
              tooltip: t.mediaMenu.playVersion,
              semanticLabel: t.videoControls.versionColumnHeader,
              semanticValue: _selectedVersion(state)?.displayLabel,
              getTotalButtons: () => totalFocusable,
              onPressed: () {
                state.onCancelAutoHide?.call();
                OverlaySheetController.of(context)
                    .show(
                      builder: (_) => BaseVideoControlSheet(
                        title: t.videoControls.versionColumnHeader,
                        icon: Symbols.video_file_rounded,
                        child: VersionQualityPicker(
                          availableVersions: state.availableVersions,
                          selectedMediaIndex: state.selectedMediaIndex,
                          selectedQualityPreset: state.selectedQualityPreset,
                          serverSupportsTranscoding: false,
                          onVersionSelected: (index) => state.onSwitchVersion?.call(index),
                          onQualitySelected: (_) {},
                        ),
                      ),
                    )
                    .whenComplete(() => state.onStartAutoHide?.call());
              },
            ),
          );
        }

        if (state.hasStreamQualities) {
          final currentIndex = totalFocusable++;
          contentGroup.add(
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: ConstrainedBox(
                  // A labelled button needs a bounded width to ellipsize in.
                  constraints: const BoxConstraints(maxWidth: 140),
                  child: _buildTrackButton(
                    buttonIndex: currentIndex,
                    label: streamQualityName(state.selectedStreamQuality),
                    pillSurface: true,
                    focusBorderRadius: const BorderRadius.all(Radius.circular(7)),
                    tooltip: t.videoControls.qualityColumnHeader,
                    semanticLabel: t.videoControls.qualityColumnHeader,
                    semanticValue: streamQualityName(state.selectedStreamQuality),
                    getTotalButtons: () => totalFocusable,
                    onPressed: () {
                      state.onCancelAutoHide?.call();
                      OverlaySheetController.of(context)
                          .show(
                            builder: (_) => BaseVideoControlSheet(
                              title: t.videoControls.qualityColumnHeader,
                              icon: Symbols.high_quality_rounded,
                              child: VersionQualityPicker(
                                // Quality only: this acts on the current file.
                                availableVersions: [?_selectedVersion(state)],
                                selectedMediaIndex: 0,
                                selectedQualityPreset: state.selectedQualityPreset,
                                serverSupportsTranscoding: false,
                                onVersionSelected: (_) {},
                                onQualitySelected: (_) {},
                                streamQualities: state.streamQualities,
                                selectedStreamQuality: state.selectedStreamQuality,
                                onStreamQualitySelected: (id) => state.onSwitchStreamQuality?.call(id),
                              ),
                            ),
                          )
                          .whenComplete(() => state.onStartAutoHide?.call());
                    },
                  ),
                ),
              ),
            ),
          );
        }

        {
          final currentIndex = totalFocusable++;
          contentGroup.add(
            StreamBuilder<TrackSelection>(
              stream: player.streams.track,
              initialData: player.state.track,
              builder: (context, selectionSnapshot) {
                final selection = selectionSnapshot.data ?? player.state.track;
                final hasSubtitleControls = state.hasSubtitleControls(tracks);
                final selectedSub = selection.subtitle;
                final hasActiveSubtitle = selectedSub != null && selectedSub.id != SubtitleTrack.off.id;
                final isHidden = hasSubtitleControls && hasActiveSubtitle && !state.subtitlesVisible;
                final icon = hasSubtitleControls
                    ? (isHidden ? Symbols.closed_caption_disabled_rounded : Symbols.closed_caption_rounded)
                    : Symbols.audiotrack_rounded;
                return _buildTrackButton(
                  buttonIndex: currentIndex,
                  icon: icon,
                  iconSize: 24,
                  iconFill: 1,
                  iconWeight: 700,
                  tooltip: t.videoControls.tracksButton,
                  semanticLabel: t.videoControls.tracksButton,
                  semanticValue: _selectionSemanticValue(tracks, selection),
                  getTotalButtons: () => totalFocusable,
                  onPressed: () {
                    state.onCancelAutoHide?.call();
                    OverlaySheetController.of(context)
                        .show(
                          builder: (_) => TrackSheet(player: player, trackControlsState: state),
                        )
                        .whenComplete(() => state.onStartAutoHide?.call());
                  },
                );
              },
            ),
          );
        }

        if (chapters.isNotEmpty && !hideChaptersAndQueue) {
          final currentIndex = totalFocusable++;
          contentGroup.add(
            _buildTrackButton(
              buttonIndex: currentIndex,
              icon: Symbols.bookmarks_rounded,
              iconSize: 24,
              iconFill: 1,
              iconWeight: 700,
              tooltip: t.videoControls.chaptersButton,
              semanticLabel: t.videoControls.chaptersButton,
              getTotalButtons: () => totalFocusable,
              onPressed: () {
                state.onCancelAutoHide?.call();
                OverlaySheetController.of(context)
                    .show(
                      builder: (_) => ChapterSheet(
                        player: player,
                        chapters: chapters,
                        chaptersLoaded: chaptersLoaded,
                        canControl: state.canControl,
                        serverId: state.serverId,
                        onSeekRequested: onSeekRequested,
                        onSeekCompleted: onSeekCompleted,
                      ),
                    )
                    .whenComplete(() => state.onStartAutoHide?.call());
              },
            ),
          );
        }

        if (state.showQueueButton && state.onQueueItemSelected != null && !hideChaptersAndQueue) {
          final currentIndex = totalFocusable++;
          contentGroup.add(
            _buildTrackButton(
              buttonIndex: currentIndex,
              icon: Symbols.playlist_play_rounded,
              iconSize: 26,
              iconFill: 1,
              iconWeight: 700,
              tooltip: t.videoControls.queue,
              semanticLabel: t.videoControls.queue,
              getTotalButtons: () => totalFocusable,
              onPressed: () {
                state.onCancelAutoHide?.call();
                OverlaySheetController.of(context)
                    .show(builder: (_) => QueueSheet(onItemSelected: state.onQueueItemSelected!))
                    .whenComplete(() => state.onStartAutoHide?.call());
              },
            ),
          );
        }

        {
          final settingsIndex = totalFocusable++;
          settingsGroup.add(
            ListenableBuilder(
              listenable: SleepTimerService(),
              builder: (context, _) {
                final sleepTimer = SleepTimerService();
                final shaderService = state.shaderService;
                final isShaderActive =
                    shaderService != null && shaderService.isSupported && shaderService.currentPreset.isEnabled;
                final isZoomActive = (state.videoZoomScale - 1.0).abs() > 0.0001;
                final isActive =
                    sleepTimer.isActive ||
                    state.audioSyncOffset != 0 ||
                    state.subtitleSyncOffset != 0 ||
                    isShaderActive ||
                    isZoomActive;
                return _buildTrackButton(
                  buttonIndex: settingsIndex,
                  icon: Symbols.settings_rounded,
                  iconSize: 24,
                  iconFill: 1,
                  iconWeight: 700,
                  isActive: isActive,
                  checked: isActive,
                  tooltip: t.videoControls.settingsButton,
                  semanticValue: _versionQualitySemanticValue(),
                  semanticLabel: t.videoControls.settingsButton,
                  getTotalButtons: () => totalFocusable,
                  onPressed: () {
                    state.onCancelAutoHide?.call();
                    OverlaySheetController.of(context)
                        .show(
                          builder: (_) => VideoSettingsSheet(player: player, trackControlsState: state),
                        )
                        .whenComplete(() => state.onStartAutoHide?.call());
                  },
                );
              },
            ),
          );
        }

        if (!isDesktop && !PlatformDetector.isTV() && state.onRemoteHandoff != null && !state.isLive) {
          final currentIndex = totalFocusable++;
          windowGroup.add(
            Builder(
              builder: (btnContext) => _buildTrackButton(
                buttonIndex: currentIndex,
                icon: Symbols.cast_rounded,
                iconSize: 24,
                iconFill: 1,
                iconWeight: 700,
                tooltip: t.companionRemote.handoffToRemote,
                semanticLabel: t.companionRemote.handoffToRemote,
                getTotalButtons: () => totalFocusable,
                onPressed: () {
                  state.onCancelAutoHide?.call();
                  unawaited(state.onRemoteHandoff!(btnContext).whenComplete(() => state.onStartAutoHide?.call()));
                },
              ),
            ),
          );
        }

        if (state.onTogglePIPMode != null) {
          final currentIndex = totalFocusable++;
          windowGroup.add(
            _buildTrackButton(
              buttonIndex: currentIndex,
              icon: Symbols.picture_in_picture_alt_rounded,
              iconSize: 24,
              iconFill: 1,
              iconWeight: 700,
              tooltip: t.videoControls.pipButton,
              semanticLabel: t.videoControls.pipButton,
              getTotalButtons: () => totalFocusable,
              onPressed: state.onTogglePIPMode,
            ),
          );
        }

        // BoxFit mode button
        if (state.onCycleBoxFitMode != null) {
          final currentIndex = totalFocusable++;
          windowGroup.add(
            _buildTrackButton(
              buttonIndex: currentIndex,
              icon: _getBoxFitIcon(state.boxFitMode),
              iconSize: 24,
              iconFill: state.boxFitMode == 0 ? 0 : 1,
              iconWeight: 700,
              tooltip: _getBoxFitTooltip(state.boxFitMode),
              semanticLabel: t.videoControls.aspectRatioButton,
              semanticValue: _getBoxFitTooltip(state.boxFitMode),
              getTotalButtons: () => totalFocusable,
              onPressed: state.onCycleBoxFitMode,
            ),
          );
        }

        // Rotation lock button (mobile only, not on TV since screens don't rotate)
        if (isMobile && !PlatformDetector.isTV()) {
          final currentIndex = totalFocusable++;
          windowGroup.add(
            _buildTrackButton(
              buttonIndex: currentIndex,
              icon: state.isRotationLocked ? Symbols.screen_lock_rotation_rounded : Symbols.screen_rotation_rounded,
              iconSize: 24,
              iconFill: 1,
              iconWeight: 700,
              tooltip: state.isRotationLocked ? t.videoControls.unlockRotation : t.videoControls.lockRotation,
              semanticLabel: t.videoControls.rotationLockButton,
              checked: state.isRotationLocked,
              getTotalButtons: () => totalFocusable,
              onPressed: state.onToggleRotationLock,
            ),
          );
        }

        // Screen lock button (mobile only, not on TV)
        if (isMobile && !PlatformDetector.isTV()) {
          final currentIndex = totalFocusable++;
          windowGroup.add(
            _buildTrackButton(
              buttonIndex: currentIndex,
              icon: Symbols.lock_rounded,
              iconSize: 24,
              iconFill: 1,
              iconWeight: 700,
              tooltip: t.videoControls.lockScreen,
              semanticLabel: t.videoControls.screenLockButton,
              getTotalButtons: () => totalFocusable,
              onPressed: state.onToggleScreenLock,
            ),
          );
        }

        // Fullscreen button (desktop only)
        if (isDesktop) {
          final currentIndex = totalFocusable++;
          windowGroup.add(
            _buildTrackButton(
              buttonIndex: currentIndex,
              icon: state.isFullscreen ? Symbols.fullscreen_exit_rounded : Symbols.fullscreen_rounded,
              iconSize: 24,
              iconFill: 1,
              iconWeight: 700,
              tooltip: state.isFullscreen ? t.videoControls.exitFullscreenButton : t.videoControls.fullscreenButton,
              semanticLabel: state.isFullscreen
                  ? t.videoControls.exitFullscreenButton
                  : t.videoControls.fullscreenButton,
              checked: state.isFullscreen,
              getTotalButtons: () => totalFocusable,
              onPressed: state.onToggleFullscreen,
            ),
          );
        }

        final groups = [contentGroup, settingsGroup, windowGroup].where((g) => g.isNotEmpty).toList();
        final buttons = <Widget>[];
        for (var i = 0; i < groups.length; i++) {
          if (i > 0) buttons.add(_buildGroupDivider(isMobile));
          buttons.addAll(groups[i]);
        }

        return IntrinsicHeight(
          child: Row(
            mainAxisSize: .min,
            crossAxisAlignment: .stretch,
            children: [
              ...buttons,
              if (showText &&
                  state.serverId == LocalLibraryClient.localServerId &&
                  state.availableVersions.isNotEmpty &&
                  !state.hasStreamQualities)
                Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(t.streamQuality.original, style: const TextStyle(color: Colors.white70)),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  static MediaVersion? _selectedVersion(TrackControlsState state) {
    final index = state.selectedMediaIndex;
    return index >= 0 && index < state.availableVersions.length ? state.availableVersions[index] : null;
  }

  String? _versionQualitySemanticValue() {
    final state = trackControlsState;
    final values = <String>[];
    if (state.availableVersions.length > 1) {
      final index = state.selectedMediaIndex;
      if (index >= 0 && index < state.availableVersions.length) {
        values.add(state.availableVersions[index].displayLabel);
      }
    }
    if (state.hasStreamQualities) {
      values.add(streamQualityName(state.selectedStreamQuality));
    } else if (state.serverSupportsTranscoding) {
      values.add(qualityPresetLabel(state.selectedQualityPreset));
    }
    return values.isEmpty ? null : values.join(' / ');
  }

  String? _selectionSemanticValue(Tracks? tracks, TrackSelection selection) {
    final values = <String>[];
    final audio = selection.audio;
    if (audio != null && audio.id != AudioTrack.off.id) {
      final index = tracks?.audio.indexWhere((track) => track.id == audio.id) ?? -1;
      final visibleIndex = index < 0 ? 0 : index;
      final label = TrackLabelBuilder.audioLabel(
        title: audio.title,
        language: audio.language,
        codec: audio.codec,
        codecProfile: audio.codecProfile,
        channels: audio.channelsCount,
        index: visibleIndex,
      );
      values.add(label.joined);
    }

    final subtitle = selection.subtitle;
    if (subtitle != null && subtitle.id != SubtitleTrack.off.id) {
      final index = tracks?.subtitle.indexWhere((track) => track.id == subtitle.id) ?? -1;
      values.add(
        TrackLabelBuilder.subtitleLabel(
          title: subtitle.title,
          language: subtitle.language,
          codec: subtitle.codec,
          forced: subtitle.isForced,
          index: index < 0 ? 0 : index,
        ).joined,
      );
    }

    return values.isEmpty ? null : values.join(', ');
  }

  IconData _getBoxFitIcon(int mode) {
    switch (mode) {
      case 0:
        return Symbols.aspect_ratio_rounded; // contain (letterbox)
      case 1:
        return Symbols.zoom_out_map_rounded; // cover (fill screen)
      case 2:
        return Symbols.settings_overscan_rounded; // fill (stretch)
      default:
        return Symbols.aspect_ratio_rounded;
    }
  }

  String _getBoxFitTooltip(int mode) {
    switch (mode) {
      case 0:
        return t.videoControls.letterbox;
      case 1:
        return t.videoControls.fillScreen;
      case 2:
        return t.videoControls.stretch;
      default:
        return t.videoControls.letterbox;
    }
  }
}
