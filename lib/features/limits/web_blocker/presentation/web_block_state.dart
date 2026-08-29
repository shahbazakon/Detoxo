import 'package:detoxo/features/limits/web_blocker/domain/entities/popular_site.dart';
import 'package:detoxo/features/limits/web_blocker/domain/entities/web_block_entry.dart';
import 'package:detoxo/features/limits/web_blocker/domain/entities/web_block_stats.dart';
import 'package:equatable/equatable.dart';

/// Immutable UI state for the website blocker screen.
class WebBlockState extends Equatable {
  const WebBlockState({
    this.isLoading = true,
    this.entries = const [],
    this.stats = const WebBlockStats(),
    this.blockAdult = false,
    this.blockForApps = false,
    this.query = '',
    this.error,
    this.loadFailed = false,
    this.unsupportedBrowsers = const [],
  });

  final bool isLoading;

  /// The blocklist could not be READ (corrupt blob, store failure) — distinct
  /// from an empty one. `entries` is then meaningless rather than empty, and
  /// the screen must not offer the "nothing blocked yet" call to action.
  final bool loadFailed;

  /// The user's saved blocklist (custom + enabled popular sites).
  final List<WebBlockEntry> entries;
  final WebBlockStats stats;
  final bool blockAdult;
  final bool blockForApps;
  final String query;

  /// Transient validation / failure message (shown once, then cleared).
  final String? error;

  /// EVO-047: labels of installed browsers the engine cannot read, so the
  /// screen can name what it does NOT cover. Empty means either "all covered"
  /// or "couldn't ask" — both render nothing, which is the safe direction.
  final List<String> unsupportedBrowsers;

  /// The curated popular-site catalogue (static).
  List<PopularSite> get popular => PopularSites.all;

  /// IDs of popular sites currently in the blocklist (drives chip selection).
  Set<String> get activePopularIds {
    final patterns = entries.map((e) => e.pattern).toSet();
    return {
      for (final s in PopularSites.all)
        if (patterns.contains(s.primaryDomain)) s.id,
    };
  }

  /// Entries filtered by the search [query] (matches host or display name).
  List<WebBlockEntry> get visibleEntries {
    if (query.isEmpty) return entries;
    final q = query.toLowerCase();
    return entries
        .where(
          (e) =>
              e.pattern.toLowerCase().contains(q) ||
              (e.displayName ?? '').toLowerCase().contains(q),
        )
        .toList();
  }

  bool get hasEntries => entries.isNotEmpty;

  bool get hasStats => stats.totalBlocked > 0 || stats.blockedToday > 0;

  /// How many batch protections are on — drives the Protection pill's count
  /// and its screen-reader announcement. Lives here, with the other derived
  /// getters, so the pill and its label can never disagree.
  int get protectionCount => (blockForApps ? 1 : 0) + (blockAdult ? 1 : 0);

  /// Total batch protections offered, so the announcement's denominator
  /// tracks the switches instead of a hardcoded literal.
  static const int protectionTotal = 2;

  WebBlockState copyWith({
    bool? isLoading,
    List<WebBlockEntry>? entries,
    WebBlockStats? stats,
    bool? blockAdult,
    bool? blockForApps,
    String? query,
    String? error,
    bool clearError = false,
    bool? loadFailed,
    List<String>? unsupportedBrowsers,
  }) => WebBlockState(
    isLoading: isLoading ?? this.isLoading,
    entries: entries ?? this.entries,
    stats: stats ?? this.stats,
    blockAdult: blockAdult ?? this.blockAdult,
    blockForApps: blockForApps ?? this.blockForApps,
    query: query ?? this.query,
    error: clearError ? null : (error ?? this.error),
    loadFailed: loadFailed ?? this.loadFailed,
    unsupportedBrowsers: unsupportedBrowsers ?? this.unsupportedBrowsers,
  );

  @override
  List<Object?> get props => [
    isLoading,
    entries,
    stats,
    blockAdult,
    blockForApps,
    query,
    error,
    loadFailed,
    unsupportedBrowsers,
  ];
}
