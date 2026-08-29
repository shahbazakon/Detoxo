import 'dart:async';

import 'package:detoxo/core/utils/app_logger.dart';
import 'package:detoxo/features/content_counter/content_counter_bubble/domain/repositories/bubble_repository.dart';
import 'package:detoxo/features/content_counter/content_counter_core/domain/entities/content_count.dart';
import 'package:detoxo/features/content_counter/content_counter_core/domain/repositories/content_counter_repository.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Streams the live [ContentCount] from the native counter into the UI and
/// owns the counter's two switches (counting master, bubble) plus the bubble's
/// overlay-grant state — the one source of truth every counter control surface
/// (Appearance, Activity, dashboard ring) reads.
class ContentCounterCubit extends Cubit<ContentCount> {
  ContentCounterCubit(this._repo, this._bubble)
    : super(const ContentCount.empty()) {
    _sub = _repo.watch().listen(
      // A streamed count carries no permission state — keep what we know.
      (c) => emit(c.copyWith(overlayGranted: state.overlayGranted)),
      // Log, don't propagate: an unhandled stream error surfaced as an
      // uncaught zone error. (Malformed events are skipped inside the
      // repository's generator, so the subscription itself stays alive.)
      onError: (Object e, StackTrace s) => AppLogger.e('counter stream', e, s),
    );
    unawaited(_readOverlay());
  }

  final ContentCounterRepository _repo;
  final BubbleRepository _bubble;
  late final StreamSubscription<ContentCount> _sub;

  Future<void> setEnabled({required bool enabled}) async {
    emit(state.copyWith(enabled: enabled));
    await _repo.setEnabled(enabled: enabled);
  }

  /// Switches the bubble; when turning it on without the overlay grant, opens
  /// the system screen. The grant is re-read on every app resume ([refresh]),
  /// so coming back from Settings clears the "needs permission" state.
  Future<void> setBubbleEnabled({required bool enabled}) async {
    emit(state.copyWith(bubbleEnabled: enabled));
    await _bubble.setEnabled(enabled: enabled);
    if (!enabled) return;
    final granted = await _readOverlay();
    if (granted == false) await _bubble.requestPermission();
  }

  /// Opens the system overlay-permission screen (the bubble card's fix action).
  Future<void> requestOverlay() => _bubble.requestPermission();

  /// Re-pulls the native snapshot so today's usage time is fresh on demand
  /// (it advances between counted reels, which the event stream doesn't emit),
  /// and re-reads the overlay grant.
  Future<void> refresh() async {
    final count = await _repo.current();
    if (isClosed) return;
    emit(count.copyWith(overlayGranted: state.overlayGranted));
    await _readOverlay();
  }

  Future<bool?> _readOverlay() async {
    final granted = await _bubble.canShow();
    if (!isClosed) emit(state.copyWith(overlayGranted: granted));
    return granted;
  }

  @override
  Future<void> close() async {
    await _sub.cancel();
    return super.close();
  }
}
