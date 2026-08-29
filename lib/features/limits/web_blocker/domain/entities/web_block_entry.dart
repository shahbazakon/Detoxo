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
    this.displayName,
    this.source = WebBlockSource.custom,
    this.brandColor,
    this.createdAt,
  });

  factory WebBlockEntry.fromJson(Map<String, dynamic> json) => WebBlockEntry(
    pattern: json['pattern'] as String? ?? '',
    matchType: WebMatchType.fromWire(json['matchType'] as String?),
    enabled: json['enabled'] as bool? ?? true,
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

  // M8: `pausedUntil` lived here from EVO-012 until the per-site pause was
  // generalised into `TemporaryUnblock`. "This target is dormant until T" is
  // now ONE mechanism for reels, apps and websites — a paused site is a
  // WEBSITE grant keyed on this pattern, and `migrateWebPauses` moves any
  // stored window across once, on the first load after upgrading.

  /// Friendly label for the UI (e.g. "YouTube"); falls back to [pattern].
  final String? displayName;

  /// Provenance of this entry — drives row affordances and analytics.
  final WebBlockSource source;

  /// Optional ARGB brand colour for the leading badge.
  final int? brandColor;

  /// When the entry was added; null for entries saved before this field
  /// existed. Recorded only — the list renders in insertion order, so nothing
  /// sorts by this yet.
  final DateTime? createdAt;

  /// Stable identity — [pattern] is unique within the blocklist.
  String get id => pattern;

  /// What to render as the row title.
  String get label => displayName ?? pattern;

  /// Whether this entry contributes to the pushed blocklist at all. A live
  /// unblock no longer changes this — it is a grant now, held by
  /// `UnblockCubit`, so the entry keeps riding the wire and native decides.
  bool get isActive => enabled;

  WebBlockEntry copyWith({
    String? pattern,
    WebMatchType? matchType,
    bool? enabled,
    String? displayName,
    WebBlockSource? source,
    int? brandColor,
    DateTime? createdAt,
  }) => WebBlockEntry(
    pattern: pattern ?? this.pattern,
    matchType: matchType ?? this.matchType,
    enabled: enabled ?? this.enabled,
    displayName: displayName ?? this.displayName,
    source: source ?? this.source,
    brandColor: brandColor ?? this.brandColor,
    createdAt: createdAt ?? this.createdAt,
  );

  Map<String, dynamic> toJson() => {
    'pattern': pattern,
    'matchType': matchType.wire,
    'enabled': enabled,
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
    displayName,
    source,
    brandColor,
    createdAt,
  ];
}
