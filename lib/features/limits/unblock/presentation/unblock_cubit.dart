import 'dart:async';
import 'dart:convert';

import 'package:detoxo/core/utils/app_logger.dart';
import 'package:detoxo/features/blocking/shared/domain/repositories/blocking_repositories.dart';
import 'package:detoxo/features/limits/unblock/domain/entities/bypass_config.dart';
import 'package:detoxo/features/limits/unblock/domain/entities/bypass_entry.dart';
import 'package:detoxo/features/limits/unblock/domain/entities/temporary_unblock.dart';
import 'package:detoxo/features/limits/unblock/domain/repositories/unblock_repositories.dart';
import 'package:detoxo/features/limits/unblock/domain/unblock_sync.dart';
import 'package:detoxo/features/limits/unblock/domain/usecases/unblock_quota.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// A target the native wall asked to unblock, parsed from `"TYPE|id"`.
class PendingUnblock extends Equatable {
  const PendingUnblock(this.targetType, this.targetId);

  /// Null for anything unparseable — a malformed value is dropped, never
  /// turned into a sheet for a target we cannot name.
  static PendingUnblock? parse(String? raw) {
    if (raw == null) return null;
    final i = raw.indexOf('|');
    if (i <= 0 || i == raw.length - 1) return null;
    final type = UnblockTargetType.fromWire(raw.substring(0, i));
    if (type == null) return null;
    return PendingUnblock(type, raw.substring(i + 1));
  }

  final UnblockTargetType targetType;
  final String targetId;

  @override
  List<Object?> get props => [targetType, targetId];
}

class UnblockState extends Equatable {
  const UnblockState({
    this.loaded = false,
    this.ledgerLoaded = false,
    this.grants = const [],
    this.active = const [],
    this.config = BypassConfig.defaults,
    this.ledger = const [],
    this.overridesLeft = 0,
    this.overridesResetAtMs = 0,
    this.grantsLeft,
    this.pending,
    this.error,
  });

  /// True once the GRANTS store came back. Every grant mutation is refused
  /// while it is false, so a failed read cannot be persisted back as an empty
  /// list and yank a live grant.
  final bool loaded;

  /// True once the LEDGER came back. Tracked separately because the two stores
  /// are independent: a corrupt ledger must cost the override quota and nothing
  /// else, and one flag for both meant it silently disabled every grant for the
  /// life of the process. Override writes gate on this one — writing a fresh
  /// ledger over a real one that merely failed to read is how a quota refunds
  /// itself.
  final bool ledgerLoaded;

  /// Everything stored, including grants that have already ended.
  final List<TemporaryUnblock> grants;

  /// The live ones, DERIVED on every resync and held in the state rather than
  /// recomputed from `DateTime.now()` at build time.
  ///
  /// This is load-bearing: `emit` is a no-op when the new state equals the old,
  /// so if a lapse changed nothing in `props` the countdown would stay on
  /// screen until some unrelated rebuild — the bug the per-site pause had
  /// before M8 moved it here, and the reason M8 needs no expiry event from
  /// native. See `UnblockCubit._armTimer`.
  ///
  /// Rows still read the clock inside their own selector: this list changing is
  /// what rebuilds them, and the read is what decides which of its entries the
  /// row is looking at.
  final List<TemporaryUnblock> active;

  final BypassConfig config;
  final List<BypassEntry> ledger;

  /// Derived from [ledger] every time, never stored — a cached count is how it
  /// drifts out of sync with the entries that produced it.
  final int overridesLeft;

  /// When the next override comes back; 0 while some are available.
  final int overridesResetAtMs;

  /// EVO-053: per-target unblocks left in the current period, or **null when
  /// grants are not rationed** (the default). Null and 0 are different
  /// sentences — the UI must not render a countdown for a budget nobody set.
  final int? grantsLeft;

  /// A wall the user tapped "Allow for a while" on, waiting for the sheet.
  final PendingUnblock? pending;

  final String? error;

  TemporaryUnblock? activeFor(UnblockTargetType type, String id, int nowMs) =>
      UnblockQuota.activeFor(active, type, id, nowMs);

  UnblockState copyWith({
    bool? loaded,
    bool? ledgerLoaded,
    List<TemporaryUnblock>? grants,
    List<TemporaryUnblock>? active,
    BypassConfig? config,
    List<BypassEntry>? ledger,
    int? overridesLeft,
    int? overridesResetAtMs,
    int? grantsLeft,
    bool clearGrantsLeft = false,
    PendingUnblock? pending,
    bool clearPending = false,
    String? error,
    bool clearError = false,
  }) => UnblockState(
    loaded: loaded ?? this.loaded,
    ledgerLoaded: ledgerLoaded ?? this.ledgerLoaded,
    grants: grants ?? this.grants,
    active: active ?? this.active,
    config: config ?? this.config,
    ledger: ledger ?? this.ledger,
    overridesLeft: overridesLeft ?? this.overridesLeft,
    overridesResetAtMs: overridesResetAtMs ?? this.overridesResetAtMs,
    grantsLeft: clearGrantsLeft ? null : (grantsLeft ?? this.grantsLeft),
    pending: clearPending ? null : (pending ?? this.pending),
    error: clearError ? null : (error ?? this.error),
  );

  @override
  List<Object?> get props => [
    loaded,
    ledgerLoaded,
    grants,
    active,
    config,
    ledger,
    overridesLeft,
    overridesResetAtMs,
    grantsLeft,
    pending,
    error,
  ];
}

/// The app-wide owner of per-target unblocks and the override quota (M8).
///
/// Provided in `main.dart` and exported from the `limits` barrel (the
/// `RulesCubit` precedent) so the App Blocker screen, the Website blocker
/// screen, the rules screen and the resume sync all reach it without a
/// boundary violation.
class UnblockCubit extends Cubit<UnblockState> {
  UnblockCubit(
    this._grants,
    this._ledgerRepo,
    this._engine, {
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now,
       super(const UnblockState());

  final TemporaryUnblockRepository _grants;
  final BypassLedgerRepository _ledgerRepo;
  final EngineRepository _engine;
  final DateTime Function() _clock;

  Timer? _timer;

  static const String saveFailed = "Couldn't save — try again";
  static const String loadFailed =
      "Your unblocks didn't load — reopen Detoxo before changing them";

  /// EVO-053. Says what ran out and when it comes back — a refusal the user
  /// cannot date is indistinguishable from a bug.
  static const String noGrantsLeft =
      "You've used today's allowances. They come back tomorrow.";

  /// Cold start and every post-wipe reload.
  Future<void> load() async {
    try {
      final ledger = await _ledgerRepo.load();
      emit(
        state.copyWith(
          ledgerLoaded: true,
          config: ledger.config,
          ledger: ledger.entries,
          clearError: true,
        ),
      );
    } on Object catch (e, s) {
      AppLogger.e('bypass ledger load failed', e, s);
      emit(state.copyWith(error: loadFailed));
    }
    // Outside the catch on purpose: the ledger and the grants are independent
    // stores, and returning early on a corrupt ledger left `loaded` false for
    // the life of the process — native was never re-pushed and every grant and
    // "end early" was silently refused. A bad ledger costs the override quota,
    // nothing else.
    await resync();
  }

  /// Re-push the active grants, re-derive everything the UI reads, and re-arm
  /// the one-shot timer. Serialised so two triggers cannot land out of order.
  Future<void> resync() {
    final next = _chain.then((_) => _resync());
    _chain = next.catchError((Object _) {});
    return next;
  }

  Future<void> _chain = Future<void>.value();

  Future<void> _resync() async {
    final grants = await syncTemporaryUnblocks(_grants, _engine, now: _clock);
    if (isClosed) return;
    final nowMs = _clock().millisecondsSinceEpoch;
    final list = grants ?? state.grants;
    emit(
      state.copyWith(
        // The grants store is usable from here — set on the read that proves
        // it, not on the ledger's, so the two failures stay independent.
        loaded: state.loaded || grants != null,
        grants: list,
        active: UnblockQuota.activeAt(list, nowMs),
        overridesLeft: UnblockQuota.effectiveRemaining(
          state.ledger,
          state.config,
          nowMs,
        ),
        overridesResetAtMs: UnblockQuota.resetsAtMs(
          state.ledger,
          state.config,
          nowMs,
        ),
        grantsLeft: UnblockQuota.grantsRemaining(
          state.ledger,
          state.config,
          nowMs,
        ),
        clearGrantsLeft: !state.config.grantsRationed,
      ),
    );
    _armTimer(UnblockQuota.nextExpiryMs(list, nowMs));
  }

  /// One-shot, re-armed on every resync — never a ticker.
  ///
  /// This is what stands in for the native expiry event the plan once
  /// specified and M8 deliberately did not ship (see `plan_docs/09`, which
  /// keeps a grep honest by asserting that token appears nowhere in the code).
  /// Detoxo is single-process, so the Dart isolate is alive in
  /// exactly the states where a native event would have had a sink to reach;
  /// and a resume re-syncs anyway (`AppResumeSync`), which covers a timer that
  /// slept through a doze. Native enforces the expiry regardless — this only
  /// stops the countdown lying.
  void _armTimer(int atMs) {
    _timer?.cancel();
    _timer = null;
    if (atMs <= 0) return;
    var delay = DateTime.fromMillisecondsSinceEpoch(atMs).difference(_clock());
    if (delay.isNegative) delay = Duration.zero;
    _timer = Timer(
      delay + const Duration(seconds: 1),
      () => unawaited(resync()),
    );
  }

  // ── Grants ──────────────────────────────────────────────────────────────

  /// Free [targetId] for [window]. A second grant on a target that is already
  /// free REPLACES the first rather than stacking, so the countdown always
  /// shows one honest number.
  ///
  /// [alsoFree] carries the extra ids one user action covers — a popular
  /// website's cross-registrable aliases, which the per-site pause has always
  /// released together.
  Future<bool> grant(
    UnblockTargetType type,
    String targetId,
    Duration window, {
    UnblockSource source = UnblockSource.wall,
    List<String> alsoFree = const [],
  }) async {
    final nowMs = _clock().millisecondsSinceEpoch;
    // EVO-053: the budget, when the user set one. Checked BEFORE anything is
    // written, the `validateOverride` contract — a refusal must never leave a
    // half-spent quota behind. `null` means unlimited, which is the default.
    final left = UnblockQuota.grantsRemaining(
      state.ledger,
      state.config,
      nowMs,
    );
    if (left != null && left <= 0) {
      emit(state.copyWith(error: noGrantsLeft));
      return false;
    }
    // Normalised BEFORE the replace scan: stored website ids are lower-cased,
    // so comparing raw input against them let "YouTube.com" stack a second
    // grant on top of the first instead of replacing it.
    final ids = _ids(type, {targetId, ...alsoFree});
    final replaced = [
      for (final g in state.grants)
        if (!(g.targetType == type && ids.contains(g.targetId))) g,
    ];
    final ok = await _commit([
      for (final id in ids)
        TemporaryUnblock(
          targetType: type,
          targetId: id,
          startMs: nowMs,
          endMs: nowMs + window.inMilliseconds,
          source: source,
        ),
      ...replaced,
    ]);
    // ONE ledger row per user action, not one per alias: freeing x.com and
    // twitter.com together is one decision and must cost one allowance.
    // Recorded even when unlimited — a budget switched on tomorrow needs
    // today's history to mean anything — and only after the grant actually
    // landed, so a failed write never spends.
    if (ok) {
      await _recordGrant(nowMs, nowMs + window.inMilliseconds, ids.first);
    }
    return ok;
  }

  /// Appends the `GRANT` row and re-derives the budget. Best-effort: the grant
  /// itself is already persisted and pushed, so a ledger failure must not
  /// report the unblock as failed — it costs the accounting, not the action.
  Future<void> _recordGrant(int nowMs, int untilMs, String targetId) async {
    final next = UnblockQuota.pruneLedger([
      BypassEntry(
        kind: BypassKind.grant,
        atMs: nowMs,
        untilMs: untilMs,
        ruleId: targetId,
      ),
      ...state.ledger,
    ]);
    try {
      await _ledgerRepo.save(BypassLedger(config: state.config, entries: next));
    } on Object catch (e, s) {
      AppLogger.e('grant ledger append failed', e, s);
      return;
    }
    if (isClosed) return;
    // Re-derived here rather than by a resync: `_commit` already resynced
    // BEFORE this row existed, so the budget it computed was one spend stale.
    emit(
      state.copyWith(
        ledger: next,
        grantsLeft: UnblockQuota.grantsRemaining(next, state.config, nowMs),
        clearGrantsLeft: !state.config.grantsRationed,
      ),
    );
  }

  /// "I'm done" — protection comes back now, not at `endMs`.
  ///
  /// [alsoEnd] mirrors [grant]'s `alsoFree`, and mirroring it is the whole
  /// point: one user action minted a grant per alias, so ending by the exact id
  /// alone left `twitter.com` open for the rest of the window while the row's
  /// pill cleared and the screen read as protected.
  Future<bool> endEarly(
    UnblockTargetType type,
    String targetId, {
    List<String> alsoEnd = const [],
  }) {
    final nowMs = _clock().millisecondsSinceEpoch;
    final ids = _ids(type, {targetId, ...alsoEnd});
    return _commit([
      for (final g in state.grants)
        if (g.targetType == type &&
            ids.contains(g.targetId) &&
            g.isActiveAt(nowMs))
          g.cancelledAt(nowMs)
        else
          g,
    ]);
  }

  /// The id set one user action covers, normalised the way [grant] stores them
  /// — websites lower-cased, blanks dropped. Shared so a grant and its matching
  /// end can never disagree about what an id looks like.
  static Set<String> _ids(UnblockTargetType type, Set<String> raw) => {
    for (final id in raw)
      if (id.trim().isNotEmpty)
        type == UnblockTargetType.website ? id.toLowerCase() : id,
  };

  Future<bool> _commit(List<TemporaryUnblock> next) async {
    if (!state.loaded) {
      emit(state.copyWith(error: loadFailed));
      return false;
    }
    final nowMs = _clock().millisecondsSinceEpoch;
    final pruned = UnblockQuota.prune(next, nowMs);
    final previous = state.grants;
    emit(
      state.copyWith(
        grants: pruned,
        active: UnblockQuota.activeAt(pruned, nowMs),
        clearError: true,
      ),
    );
    try {
      await _grants.save(pruned);
    } on Object catch (e, s) {
      AppLogger.e('temporary unblock save failed', e, s);
      emit(
        state.copyWith(
          grants: previous,
          active: UnblockQuota.activeAt(previous, nowMs),
          error: saveFailed,
        ),
      );
      return false;
    }
    await resync();
    return true;
  }

  // ── Overrides ───────────────────────────────────────────────────────────

  /// Spend one override to lift [ruleId] for [window]. Returns the refusal, or
  /// null on success.
  ///
  /// Every validation runs BEFORE anything is written: a refusal must never
  /// leave a half-spent quota behind. The caller re-pushes the rules snapshot
  /// (`RulesCubit.resync`), which subtracts the window from that rule.
  Future<String?> requestOverride({
    required String ruleId,
    required OverrideReason? reason,
    required Duration window,
    bool enforcingNow = true,
  }) async {
    if (!state.ledgerLoaded) return loadFailed;
    final nowMs = _clock().millisecondsSinceEpoch;
    final endMs = nowMs + window.inMilliseconds;
    final refused = UnblockQuota.validateOverride(
      entries: state.ledger,
      config: state.config,
      reason: reason,
      startMs: nowMs,
      endMs: endMs,
      nowMs: nowMs,
      enforcingNow: enforcingNow,
    );
    if (refused != null) {
      emit(state.copyWith(error: refused));
      return refused;
    }
    final next = UnblockQuota.pruneLedger([
      BypassEntry(
        kind: BypassKind.override,
        atMs: nowMs,
        untilMs: endMs,
        ruleId: ruleId,
        reason: reason,
      ),
      ...state.ledger,
    ]);
    try {
      await _ledgerRepo.save(BypassLedger(config: state.config, entries: next));
    } on Object catch (e, s) {
      AppLogger.e('override save failed', e, s);
      emit(state.copyWith(error: saveFailed));
      return saveFailed;
    }
    emit(
      state.copyWith(
        ledger: next,
        overridesLeft: UnblockQuota.effectiveRemaining(
          next,
          state.config,
          nowMs,
        ),
        overridesResetAtMs: UnblockQuota.resetsAtMs(next, state.config, nowMs),
        clearError: true,
      ),
    );
    return null;
  }

  /// EVO-053: set the per-period allowance for grants. `0` means unlimited,
  /// which is the shipped default.
  ///
  /// Deliberately NOT rationed itself: raising your own allowance is a decision
  /// you make in Settings, behind the PIN if one is set, and pretending
  /// otherwise would be theatre — the honest friction is that the count is
  /// visible every time you spend one.
  Future<bool> setGrantLimit(int limit) async {
    if (!state.ledgerLoaded) {
      emit(state.copyWith(error: loadFailed));
      return false;
    }
    final config = state.config.copyWith(grantLimit: limit);
    try {
      await _ledgerRepo.save(
        BypassLedger(config: config, entries: state.ledger),
      );
    } on Object catch (e, s) {
      AppLogger.e('grant limit save failed', e, s);
      emit(state.copyWith(error: saveFailed));
      return false;
    }
    emit(state.copyWith(config: config, clearError: true));
    await resync();
    return true;
  }

  /// The live lift on [ruleId], or null.
  BypassEntry? activeOverrideFor(String ruleId) =>
      UnblockQuota.activeOverrideFor(
        state.ledger,
        ruleId,
        _clock().millisecondsSinceEpoch,
      );

  // ── The wall hand-off ───────────────────────────────────────────────────

  /// Drains the target of an "Allow for a while" tap. Called from the
  /// bootstrap's background phase and from every resume: the tap foregrounds
  /// Detoxo, and on a cold start the EventChannel is not attached yet, so this
  /// read — not the `blockScreenAction` event — is what actually delivers it.
  Future<void> takePending() async {
    try {
      final pending = PendingUnblock.parse(await _engine.takePendingUnblock());
      if (pending == null || isClosed) return;
      emit(state.copyWith(pending: pending));
    } on Object catch (e, s) {
      AppLogger.e('pending unblock read failed', e, s);
    }
  }

  /// EVO-050: fold in the grants the user took **on the wall itself**.
  ///
  /// Native already enforces them — it wrote them into its own list and
  /// refreshed the registry on the spot, which is the whole point of asking the
  /// question where the block happened. This is the other half: Hive owns the
  /// history, and the next `syncTemporaryUnblocks` rewrites native's list
  /// wholesale, so without this the push that follows would delete the grant
  /// the user just took.
  ///
  /// Read-and-clear natively, so a row is absorbed exactly once. Rows that have
  /// already expired are dropped by `prune` inside `_commit`.
  Future<void> absorbNativeGrants() async {
    final String? raw;
    try {
      raw = await _engine.takeNativeGrants();
    } on Object catch (e, s) {
      AppLogger.e('native grant read failed', e, s);
      return;
    }
    if (raw == null || raw.isEmpty || isClosed) return;
    final List<dynamic> rows;
    try {
      rows = jsonDecode(raw) as List<dynamic>;
    } on Object catch (e, s) {
      AppLogger.e('native grants unreadable', e, s);
      return;
    }
    final nowMs = _clock().millisecondsSinceEpoch;
    final absorbed = <TemporaryUnblock>[];
    for (final row in rows) {
      if (row is! Map) continue;
      final type = UnblockTargetType.fromWire(row['targetType'] as String?);
      final id = (row['targetId'] as String? ?? '').trim();
      final endMs = row['endMs'] is num ? (row['endMs']! as num).toInt() : 0;
      // `startMs` is not on the wire — native has no use for it, and the row is
      // live by definition when it arrives. Stamping it NOW rather than
      // guessing backwards keeps `isActiveAt` true without inventing history.
      if (type == null || id.isEmpty || endMs <= nowMs) continue;
      absorbed.add(
        TemporaryUnblock(
          targetType: type,
          targetId: type == UnblockTargetType.website ? id.toLowerCase() : id,
          startMs: nowMs,
          endMs: endMs,
          // `source: wall` is the default, and it is the truth here — this row
          // only exists because a wall chip was tapped.
        ),
      );
    }
    if (absorbed.isEmpty) return;
    final keys = {
      for (final g in absorbed) '${g.targetType.wire}|${g.targetId}',
    };
    await _commit([
      ...absorbed,
      for (final g in state.grants)
        if (!keys.contains('${g.targetType.wire}|${g.targetId}')) g,
    ]);
    // The wall is a spend like any other, and the ledger is what makes a budget
    // set tomorrow mean anything (EVO-053). One row per absorbed grant.
    for (final g in absorbed) {
      await _recordGrant(g.startMs, g.endMs, g.targetId);
    }
  }

  /// Consumed by the listener that opened the sheet, so backing out of it does
  /// not re-open it on the next rebuild.
  void clearPending() => emit(state.copyWith(clearPending: true));

  void clearError() => emit(state.copyWith(clearError: true));

  @override
  Future<void> close() {
    _timer?.cancel();
    return super.close();
  }
}
