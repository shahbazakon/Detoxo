import 'dart:convert';

import 'package:detoxo/core/platform_channels/engine_channel.dart';
import 'package:detoxo/core/utils/app_logger.dart';
import 'package:detoxo/features/content_counter/content_counter_bubble/domain/entities/bubble_style.dart';
import 'package:detoxo/features/content_counter/content_counter_core/domain/entities/counter_appearance.dart';
import 'package:detoxo/features/content_counter/content_counter_core/domain/repositories/counter_appearance_repository.dart';
import 'package:detoxo/features/content_counter/home_content_counter/domain/entities/widget_style.dart';

/// Bridges the counter appearance to native: hydrates from the counter snapshot
/// (which carries the persisted style JSON) and pushes changes over the single
/// `setCounterStyle` command.
class CounterAppearanceRepositoryImpl implements CounterAppearanceRepository {
  CounterAppearanceRepositoryImpl(this._channel);

  final EngineChannel _channel;

  @override
  Future<CounterAppearance> current() async {
    final snap = await _channel.contentCounterSnapshot();
    return CounterAppearance(
      bubble: BubbleStyle.fromWire(_decode(snap['bubbleStyle'])),
      widget: WidgetStyle.fromWire(_decode(snap['widgetStyle'])),
    );
  }

  @override
  Future<void> setBubbleStyle(BubbleStyle style) =>
      _channel.setCounterStyle(bubble: style.toWire());

  @override
  Future<void> setWidgetStyle(WidgetStyle style) =>
      _channel.setCounterStyle(widget: style.toWire());

  /// Parses a persisted style value. Native stores each style as a JSON string;
  /// returns null (→ entity defaults) when absent, empty, or malformed — the
  /// malformed case is logged, since it silently resets the user's styling.
  Map<String, dynamic>? _decode(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } on Object catch (e) {
      AppLogger.e('counter style decode', e);
      return null;
    }
  }
}
