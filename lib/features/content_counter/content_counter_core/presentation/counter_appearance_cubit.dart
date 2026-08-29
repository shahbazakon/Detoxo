import 'dart:async';

import 'package:detoxo/features/content_counter/content_counter_bubble/domain/entities/bubble_style.dart';
import 'package:detoxo/features/content_counter/content_counter_core/domain/entities/counter_appearance.dart';
import 'package:detoxo/features/content_counter/content_counter_core/domain/repositories/counter_appearance_repository.dart';
import 'package:detoxo/features/content_counter/home_content_counter/domain/entities/widget_style.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Owns the live-edited counter appearance. Each setter emits immediately (so
/// the on-screen preview tracks the control with no lag) but debounces the
/// native push, so dragging a slider doesn't flood the command channel — only
/// the settled value is persisted / live-rendered on the real bubble & widget.
///
/// One app-wide instance (provided in `main.dart`, created lazily on first
/// use): the Appearance hub and both editors read and write the same state, so
/// an edit is visible everywhere without re-pulling the native snapshot.
class CounterAppearanceCubit extends Cubit<CounterAppearance> {
  CounterAppearanceCubit(this._repo)
    : super(const CounterAppearance.defaults()) {
    unawaited(_load());
  }

  final CounterAppearanceRepository _repo;

  Timer? _bubbleDebounce;
  Timer? _widgetDebounce;

  // An edit that beats the hydrate must win: without these, `_load` landing
  // after a first slider drag snapped the preview back to the persisted style
  // while native already held the new one.
  bool _bubbleDirty = false;
  bool _widgetDirty = false;

  static const Duration _debounce = Duration(milliseconds: 120);

  Future<void> _load() async {
    final loaded = await _repo.current();
    if (isClosed) return;
    emit(
      state.copyWith(
        bubble: _bubbleDirty ? state.bubble : loaded.bubble,
        widget: _widgetDirty ? state.widget : loaded.widget,
      ),
    );
  }

  void setBubble(BubbleStyle style) {
    _bubbleDirty = true;
    emit(state.copyWith(bubble: style));
    _bubbleDebounce?.cancel();
    _bubbleDebounce = Timer(_debounce, () {
      unawaited(_repo.setBubbleStyle(style));
    });
  }

  void setWidget(WidgetStyle style) {
    _widgetDirty = true;
    emit(state.copyWith(widget: style));
    _widgetDebounce?.cancel();
    _widgetDebounce = Timer(_debounce, () {
      unawaited(_repo.setWidgetStyle(style));
    });
  }

  @override
  Future<void> close() {
    _bubbleDebounce?.cancel();
    _widgetDebounce?.cancel();
    return super.close();
  }
}
