import 'dart:async';

import 'package:detoxo/core/utils/app_logger.dart';
import 'package:detoxo/features/blocking/block_screen/domain/entities/block_screen_payload.dart';
import 'package:detoxo/features/blocking/block_screen/domain/entities/block_screen_style.dart';
import 'package:detoxo/features/blocking/block_screen/domain/repositories/block_screen_repository.dart';
import 'package:detoxo/features/content_counter/content_counter_core/domain/entities/counter_style_enums.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Owns the live-edited block-screen style (the `CounterAppearanceCubit`
/// shape): every setter emits immediately so the preview tracks the control,
/// and debounces the native push so a burst of taps persists once.
///
/// One app-wide instance (provided in `main.dart`): the Appearance hub's card
/// and the editor read and write the same state.
class BlockScreenStyleCubit extends Cubit<BlockScreenStyle> {
  BlockScreenStyleCubit(this._repo) : super(const BlockScreenStyle.defaults()) {
    unawaited(_load());
  }

  final BlockScreenRepository _repo;

  Timer? _debounce;

  // An edit that beats the hydrate must win — see CounterAppearanceCubit.
  bool _dirty = false;

  static const Duration _debounceFor = Duration(milliseconds: 120);

  Future<void> _load() async {
    try {
      final loaded = await _repo.style();
      if (isClosed || _dirty) return;
      emit(loaded);
    } on Object catch (e, s) {
      AppLogger.e('block screen style load failed', e, s);
    }
  }

  void setStyle(BlockScreenStyle style) {
    _dirty = true;
    emit(style);
    _debounce?.cancel();
    _debounce = Timer(_debounceFor, () {
      unawaited(_repo.setStyle(style));
    });
  }

  void setEnabled({required bool enabled}) =>
      setStyle(state.copyWith(enabled: enabled));
  void setTheme(WidgetTheme theme) => setStyle(state.copyWith(theme: theme));
  void setBackground(WidgetBackground background) =>
      setStyle(state.copyWith(background: background));
  void setShowCount({required bool show}) =>
      setStyle(state.copyWith(showCount: show));
  void setShowOpens({required bool show}) =>
      setStyle(state.copyWith(showOpens: show));
  void setAccentByUsage({required bool on}) =>
      setStyle(state.copyWith(accentByUsage: on));
  void setBackDelay({required bool on}) =>
      setStyle(state.copyWith(backDelaySec: on ? 5 : 0));

  /// Raises the real wall over the editor ("Try it on your phone"). False when
  /// the wall is switched off or there is no native side.
  Future<bool> preview(BlockScreenPayload payload) => _repo.preview(payload);

  @override
  Future<void> close() {
    _debounce?.cancel();
    return super.close();
  }
}
