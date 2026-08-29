import 'package:equatable/equatable.dart';

/// Hard cap on stored grants: native scans the pushed list per accessibility
/// event, so it stays small. Mirrors `UnblockRegistry.MAX_GRANTS`.
const int maxTemporaryUnblocks = 50;

/// What a grant frees. The wire strings are a storage AND channel contract —
/// a rename is a migration on both sides.
enum UnblockTargetType {
  /// A reel surface, by `platformId` (`ig_reels`). Unblocking Instagram's
  /// reels does not unblock the Instagram app, and vice versa — that split is
  /// the product's whole premise.
  reel('REEL'),

  /// A whole app, by package name.
  app('APP'),

  /// A website, by host. Native also matches subdomains of it.
  website('WEBSITE');

  const UnblockTargetType(this.wire);

  final String wire;

  /// Null for an unknown token so the caller drops the row rather than
  /// guessing which dimension it was meant to free.
  static UnblockTargetType? fromWire(String? v) {
    for (final t in values) {
      if (t.wire == v) return t;
    }
    return null;
  }
}

/// Where a grant came from. Recorded for the history list and for analytics,
/// never for enforcement — native cannot tell one source from another, and
/// deliberately so (see [TemporaryUnblock]).
///
/// There is no `OVERRIDE` member: lifting a locked rule is scoped to the RULE,
/// not to its targets, and is expressed by splitting that rule's windows in the
/// snapshot. A target-shaped grant would also lift every sibling rule and the
/// App Blocker row for the same app, which is not what an override promises.
enum UnblockSource {
  /// The "Allow for a while" button on the native block screen.
  wall('WALL'),

  /// The swipe action on an App Blocker / Website blocker row.
  blocklistRow('BLOCKLIST_ROW');

  const UnblockSource(this.wire);

  final String wire;

  static UnblockSource fromWire(String? v) =>
      v == blocklistRow.wire ? blocklistRow : wall;
}

/// One "let me into this for a while" grant.
///
/// The generalisation of the web blocker's per-site pause (EVO-012): one
/// target, dormant until a timestamp, with expiry enforced NATIVELY so it
/// re-arms even if Detoxo is never reopened.
///
/// Every field is read null- and type-tolerantly, so a document written by a
/// newer build degrades a field instead of throwing out the whole list.
class TemporaryUnblock extends Equatable {
  const TemporaryUnblock({
    required this.targetType,
    required this.targetId,
    required this.startMs,
    required this.endMs,
    this.cancelledMs,
    this.source = UnblockSource.wall,
  });

  /// Null when the row is unusable (unknown type, empty id, inverted window) —
  /// the repository drops such a document on its own rather than pushing a
  /// grant it cannot express.
  static TemporaryUnblock? fromJson(Map<String, dynamic> m) {
    final type = UnblockTargetType.fromWire(_str(m['targetType']));
    final id = (_str(m['targetId']) ?? '').trim();
    final start = _int(m['startMs']);
    final end = _int(m['endMs']);
    if (type == null || id.isEmpty || end <= start) return null;
    return TemporaryUnblock(
      targetType: type,
      targetId: type == UnblockTargetType.website ? id.toLowerCase() : id,
      startMs: start,
      endMs: end,
      cancelledMs: m['cancelledMs'] is num
          ? (m['cancelledMs']! as num).toInt()
          : null,
      source: UnblockSource.fromWire(_str(m['source'])),
    );
  }

  final UnblockTargetType targetType;

  /// `platformId` | package | host, by [targetType].
  final String targetId;

  final int startMs;
  final int endMs;

  /// Set by "I'm done" — protection comes back immediately, not at [endMs].
  /// A separate field rather than rewriting [endMs] so the history stays
  /// honest about what was asked for versus what was used.
  final int? cancelledMs;

  final UnblockSource source;

  bool isActiveAt(int nowMs) =>
      cancelledMs == null && startMs <= nowMs && nowMs < endMs;

  /// Whether this row can be dropped: cancelled, or already over.
  bool isSpentAt(int nowMs) => cancelledMs != null || endMs <= nowMs;

  /// The same grant, ended now. [nowMs] is clamped into the window so a
  /// cancellation can never read as having happened before it started.
  TemporaryUnblock cancelledAt(int nowMs) => TemporaryUnblock(
    targetType: targetType,
    targetId: targetId,
    startMs: startMs,
    endMs: endMs,
    cancelledMs: nowMs < startMs ? startMs : nowMs,
    source: source,
  );

  Map<String, dynamic> toJson() => {
    'targetType': targetType.wire,
    'targetId': targetId,
    'startMs': startMs,
    'endMs': endMs,
    'cancelledMs': cancelledMs,
    'source': source.wire,
  };

  /// The three keys native reads. Deliberately smaller than the stored
  /// document: `startMs` has already passed by the time this is pushed,
  /// `cancelledMs` rows are omitted entirely, and `source` is Dart's business.
  Map<String, dynamic> toWire() => {
    'targetType': targetType.wire,
    'targetId': targetId,
    'endMs': endMs,
  };

  @override
  List<Object?> get props => [
    targetType,
    targetId,
    startMs,
    endMs,
    cancelledMs,
    source,
  ];
}

// Type-tolerant, not just null-tolerant: a wrong-typed field in one stored
// document must degrade that row, never throw out the whole list.
String? _str(Object? v) => v is String ? v : null;

int _int(Object? v) => v is num ? v.toInt() : 0;
