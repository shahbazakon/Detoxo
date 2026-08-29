import 'package:detoxo/features/content_counter/content_counter_core/domain/entities/counter_style_enums.dart';
import 'package:equatable/equatable.dart';

/// User-tunable appearance of the block screen, plus its on/off switch.
///
/// Persisted natively in `ConfigStore` (`block_screen_style`, as JSON) and
/// pushed over `setBlockScreenStyle`; the native renderer and the Flutter
/// `BlockScreenPreview` both render from these fields. Theme and background
/// reuse the home widget's vocabulary so both surfaces share one palette.
class BlockScreenStyle extends Equatable {
  const BlockScreenStyle({
    this.enabled = true,
    this.theme = WidgetTheme.system,
    this.background = WidgetBackground.glassDark,
    this.showCount = true,
    this.showOpens = true,
    this.accentByUsage = false,
    this.backDelaySec = 5,
  });

  const BlockScreenStyle.defaults() : this();

  /// Tolerant: a wrong-typed field takes its default rather than throwing —
  /// a malformed persisted style must never leave the wall unconfigurable.
  factory BlockScreenStyle.fromWire(Map<String, dynamic>? m) {
    if (m == null || m.isEmpty) return const BlockScreenStyle.defaults();
    return BlockScreenStyle(
      enabled: _bool(m['enabled'], true),
      theme: WidgetTheme.fromWire(
        m['theme'] is String ? m['theme'] as String : null,
      ),
      background: WidgetBackground.fromWire(
        m['background'] is String ? m['background'] as String : null,
      ),
      showCount: _bool(m['showCount'], true),
      showOpens: _bool(m['showOpens'], true),
      accentByUsage: _bool(m['accentByUsage'], false),
      backDelaySec: _int(m['backDelaySec'], 5).clamp(0, 60),
    );
  }

  /// Off → blocks fall back to the toast + Back/Home they always had.
  final bool enabled;
  final WidgetTheme theme;
  final WidgetBackground background;

  /// Show "N reels today" on reel blocks.
  final bool showCount;

  /// Show "Instagram opened N times today" from the usage layer (EVO-027).
  final bool showOpens;

  /// Tint the accent by today's usage band (green→red).
  final bool accentByUsage;

  /// Seconds before "Back to {app}" unlocks (EVO-025); 0 = instant.
  final int backDelaySec;

  BlockScreenStyle copyWith({
    bool? enabled,
    WidgetTheme? theme,
    WidgetBackground? background,
    bool? showCount,
    bool? showOpens,
    bool? accentByUsage,
    int? backDelaySec,
  }) => BlockScreenStyle(
    enabled: enabled ?? this.enabled,
    theme: theme ?? this.theme,
    background: background ?? this.background,
    showCount: showCount ?? this.showCount,
    showOpens: showOpens ?? this.showOpens,
    accentByUsage: accentByUsage ?? this.accentByUsage,
    backDelaySec: backDelaySec ?? this.backDelaySec,
  );

  Map<String, dynamic> toWire() => {
    'enabled': enabled,
    'theme': theme.wire,
    'background': background.wire,
    'showCount': showCount,
    'showOpens': showOpens,
    'accentByUsage': accentByUsage,
    'backDelaySec': backDelaySec,
  };

  @override
  List<Object?> get props => [
    enabled,
    theme,
    background,
    showCount,
    showOpens,
    accentByUsage,
    backDelaySec,
  ];
}

bool _bool(Object? v, bool fallback) => v is bool ? v : fallback;
int _int(Object? v, int fallback) => v is num ? v.toInt() : fallback;
