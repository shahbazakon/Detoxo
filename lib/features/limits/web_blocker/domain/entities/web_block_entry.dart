import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
import 'package:detoxo/features/limits/web_blocker/domain/entities/web_block_source.dart';
import 'package:equatable/equatable.dart';

/// A website blocklist entry. The actual host matching runs natively (see the
/// `WebBlockEngine` on the Android side); the Dart layer owns CRUD and
/// persistence — the channel payload is built by `syncWebBlocklist`.
class WebBlockEntry extends Equatable {
  const WebBlockEntry({
    required this.pattern,
    this.matchType = WebMatchType.domain,
    this.enabled = true,
    this.pausedUntil,
    this.displayName,
    this.source = WebBlockSource.custom,
    this.brandColor,
    this.createdAt,
  });

  factory WebBlockEntry.fromJson(Map<String, dynamic> json) => WebBlockEntry(
    pattern: json['pattern'] as String? ?? '',
    matchType: WebMatchType.fromWire(json['matchType'] as String?),
    enabled: json['enabled'] as bool? ?? true,
    pausedUntil: json['pausedUntil'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(json['pausedUntil'] as int),
    displayName: json['displayName'] as String?,
    source: WebBlockSource.fromWire(json['source'] as String?),
    brandColor: json['brandColor'] as int?,
    createdAt: json['createdAt'] == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(json['createdAt'] as int),
  );

  final String pattern;
  final WebMatchType matchType;
  final bool enabled;

  /// Per-site pause: while in the future, native skips this rule and re-arms
  /// it at expiry (enforced natively, so it survives the app never reopening).
  final DateTime? pausedUntil;

  /// Friendly label for the UI (e.g. "YouTube"); falls back to [pattern].
  final String? displayName;

  /// Provenance of this entry — drives row affordances and analytics.
  final WebBlockSource source;

  /// Optional ARGB brand colour for the leading badge.
  final int? brandColor;

  /// When the entry was added (newest-first ordering); null for legacy entries.
  final DateTime? createdAt;

  /// Stable identity — [pattern] is unique within the blocklist.
  String get id => pattern;

  /// What to render as the row title.
  String get label => displayName ?? pattern;

  /// Pure, clock-injectable form of [isActive] (repo test idiom).
  bool isActiveAt(DateTime now) =>
      enabled && (pausedUntil == null || pausedUntil!.isBefore(now));

  bool get isActive => isActiveAt(DateTime.now());

  /// Whether the pause window is currently holding at [now].
  bool isPausedAt(DateTime now) =>
      enabled && pausedUntil != null && pausedUntil!.isAfter(now);

  WebBlockEntry copyWith({
    String? pattern,
    WebMatchType? matchType,
    bool? enabled,
    DateTime? pausedUntil,
    bool clearPause = false,
    String? displayName,
    WebBlockSource? source,
    int? brandColor,
    DateTime? createdAt,
  }) => WebBlockEntry(
    pattern: pattern ?? this.pattern,
    matchType: matchType ?? this.matchType,
    enabled: enabled ?? this.enabled,
    pausedUntil: clearPause ? null : (pausedUntil ?? this.pausedUntil),
    displayName: displayName ?? this.displayName,
    source: source ?? this.source,
    brandColor: brandColor ?? this.brandColor,
    createdAt: createdAt ?? this.createdAt,
  );

  Map<String, dynamic> toJson() => {
    'pattern': pattern,
    'matchType': matchType.wire,
    'enabled': enabled,
    'pausedUntil': pausedUntil?.millisecondsSinceEpoch,
    'displayName': displayName,
    'source': source.wire,
    'brandColor': brandColor,
    'createdAt': createdAt?.millisecondsSinceEpoch,
  };

  @override
  List<Object?> get props => [
    pattern,
    matchType,
    enabled,
    pausedUntil,
    displayName,
    source,
    brandColor,
    createdAt,
  ];
}
