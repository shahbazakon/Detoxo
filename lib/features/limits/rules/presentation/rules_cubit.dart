import 'dart:async';

import 'package:detoxo/core/utils/app_logger.dart';
import 'package:detoxo/features/blocking/shared/domain/repositories/blocking_repositories.dart';
import 'package:detoxo/features/limits/daily_limit/domain/repositories/daily_limit_repository.dart';
import 'package:detoxo/features/limits/rules/domain/entities/rule.dart';
import 'package:detoxo/features/limits/rules/domain/entities/rule_snapshot.dart';
import 'package:detoxo/features/limits/rules/domain/repositories/rule_repository.dart';
import 'package:detoxo/features/limits/rules/domain/rule_sync.dart';
import 'package:detoxo/features/limits/rules/domain/usecases/lock_guard.dart';
import 'package:detoxo/features/limits/unblock/domain/repositories/unblock_repositories.dart';
import 'package:detoxo/features/usage/usage.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

class RulesState extends Equatable {
  const RulesState({
    this.isLoading = false,
    this.loaded = false,
    this.rules = const [],
    this.statuses = const {},
    this.hasUsageAccess,
    this.error,
  });

  final bool isLoading;

  /// True once [rules] actually came back from the store. A failed load leaves
  /// it false with an empty list, and every mutation is refused while it is —
  /// otherwise the first save would write that empty list over the real one.
  final bool loaded;

  final List<Rule> rules;

  /// Per-rule status from the last resolve; missing = [RuleStatus.off].
  final Map<String, RuleStatus> statuses;

  /// Tri-state Usage Access grant (null = unknown / not needed); read only
  /// while a limit rule exists.
  final bool? hasUsageAccess;
  final String? error;

  int get enabledCount => rules.where((r) => r.enabled).length;

  int get activeCount =>
      rules.where((r) => r.enabled && statusOf(r).activeNow).length;

  bool get hasLimitRule => rules.any((r) => r.enabled && r.kind.isLimit);

  RuleStatus statusOf(Rule r) => statuses[r.id] ?? RuleStatus.off;

  RulesState copyWith({
    bool? isLoading,
    bool? loaded,
    List<Rule>? rules,
    Map<String, RuleStatus>? statuses,
    bool? hasUsageAccess,
    String? error,
    bool clearError = false,
  }) => RulesState(
    isLoading: isLoading ?? this.isLoading,
    loaded: loaded ?? this.loaded,
    rules: rules ?? this.rules,
    statuses: statuses ?? this.statuses,
    hasUsageAccess: hasUsageAccess ?? this.hasUsageAccess,
    error: clearError ? null : (error ?? this.error),
  );

  @override
  List<Object?> get props => [
    isLoading,
    loaded,
    rules,
    statuses,
    hasUsageAccess,
    error,
  ];
}

/// The app-wide rules owner (provided in `main.dart`): the list, each rule's
/// live status, and THE Dart push path — every mutation, `load()`, a resume
/// (`AppResumeSync`), a native `ruleBoundary`, and a one-shot timer to the
/// next boundary all funnel into [resync], which runs [syncRules].
///
/// Mutations are optimistic (`WebBlockCubit._commit`): emit, persist, revert
/// on a failed save, then re-push.
class RulesCubit extends Cubit<RulesState> {
  RulesCubit(
    this._rules,
    this._dailyLimit,
    this._usage,
    this._engine, {
    BypassLedgerRepository? ledger,
    DateTime Function()? clock,
    // A named-optional cannot name a private field, so an initializing formal
    // is not available here — making the field public is the only alternative,
    // and every other dependency on this class is private.
    // ignore: prefer_initializing_formals
  }) : _ledger = ledger,
       _clock = clock ?? DateTime.now,
       super(const RulesState(isLoading: true)) {
    _boundary = _engine.ruleBoundaryStream().listen((_) => resync());
  }

  final RuleRepository _rules;
  final DailyLimitRepository _dailyLimit;
  final UsageRepository _usage;
  final EngineRepository _engine;

  /// M8: read on every resync so an active override is subtracted from the
  /// locked rule it lifts before the snapshot is pushed. Optional, and null
  /// means "no lift" — the fail-safe direction, and what a test with no locked
  /// rules wants anyway.
  final BypassLedgerRepository? _ledger;

  final DateTime Function() _clock;

  StreamSubscription<int>? _boundary;
  Timer? _timer;
  RulesSnapshot? _lastSnapshot;

  static const String saveFailed = "Couldn't save — try again";

  /// Shown when the 50-rule cap is hit — by the cubit AND by the screen's
  /// pre-check, so the two cannot drift.
  static const String capReached = 'You can have up to $maxRules rules';

  /// Shown when a mutation is refused because the list never loaded.
  static const String loadFailed =
      "Your rules didn't load — reopen Detoxo before changing them";

  Future<void> load() async {
    try {
      final rules = await _rules.load();
      emit(
        state.copyWith(
          rules: rules,
          loaded: true,
          isLoading: false,
          clearError: true,
        ),
      );
    } on Object catch (e, s) {
      AppLogger.e('rules load failed', e, s);
      emit(state.copyWith(isLoading: false, error: "Couldn't load your rules"));
      return;
    }
    await resync();
  }

  /// Serialised so two triggers can never overlap: a cold start fires both
  /// `load()` and the Daily Limit listener, and without this their pushes could
  /// land out of order and leave native holding the OLDER snapshot.
  ///
  /// Also coalesced: a trigger that lands while one is queued but not yet
  /// started joins it. A resume, the rules screen's post-frame resync and the
  /// +1 s boundary timer otherwise ran three full read-query-resolve-push
  /// cycles back to back, each redundant with the last. One already RUNNING
  /// is not joined — a mutation during it must re-run on the new state.
  Future<void> resync() {
    final queued = _queued;
    if (queued != null) return queued;
    final next = _chain.then((_) {
      _queued = null;
      return _resync();
    });
    _queued = next;
    _chain = next.catchError((Object _) {});
    return next;
  }

  Future<void> _chain = Future<void>.value();
  Future<void>? _queued;

  /// Re-resolve + re-push the snapshot, refresh every status and (while a
  /// limit rule exists) the Usage Access grant; re-arm the boundary timer.
  Future<void> _resync() async {
    final eval = await syncRules(
      _rules,
      _dailyLimit,
      _usage,
      _engine,
      now: _clock,
      previous: _lastSnapshot,
      ledger: _ledger,
    );
    // Held so a usage read that fails (transiently, or because the user just
    // revoked the grant) cannot drop a limit entry that is already blocking.
    // Session-scoped by design: after a process restart there is nothing to
    // carry, and spent state is re-derived from UsageStats as before.
    if (eval != null) _lastSnapshot = eval.snapshot;
    final access = state.hasLimitRule ? await _usage.hasAccess() : null;
    if (isClosed) return;
    emit(
      state.copyWith(
        statuses: eval?.statuses ?? state.statuses,
        hasUsageAccess: access,
      ),
    );
    _armTimer(eval?.snapshot.nextBoundaryMs ?? 0);
  }

  /// Insert or replace by id. False (with [RulesState.error]) when the cap is
  /// hit or the save failed.
  Future<bool> save(Rule rule) {
    final invalid = rule.validate();
    if (invalid != null) {
      emit(state.copyWith(error: invalid));
      return Future.value(false);
    }
    final next = [...state.rules];
    final i = next.indexWhere((r) => r.id == rule.id);
    if (i >= 0) {
      next[i] = rule;
    } else {
      if (next.length >= maxRules) {
        emit(state.copyWith(error: capReached));
        return Future.value(false);
      }
      next.add(rule);
    }
    return _commit(next);
  }

  Future<bool> remove(String id) =>
      _commit([...state.rules.where((r) => r.id != id)]);

  Future<bool> setEnabled(String id, {required bool enabled}) => _commit([
    for (final r in state.rules)
      if (r.id == id) r.copyWith(enabled: enabled) else r,
  ]);

  void clearError() => emit(state.copyWith(clearError: true));

  Future<bool> _commit(List<Rule> next) async {
    // Never write a list built on top of rules we failed to read: the store
    // still holds the real ones (the repository THROWS on a corrupt blob rather
    // than reporting an empty list), and saving here would replace them.
    if (!state.loaded) {
      emit(state.copyWith(error: loadFailed));
      return false;
    }
    // M8: the locked-rule invariant, checked here rather than in each of
    // `save` / `remove` / `setEnabled` — one choke point, and a fourth mutation
    // added later inherits it. Enforced in the domain, not only in the UI:
    // this cubit is reachable from the dashboard card, the resume sync and the
    // splash reload, and a rule that can be disabled through a side door is not
    // locked.
    final refused = LockGuard.check(state.rules, next);
    if (refused != null) {
      emit(state.copyWith(error: refused));
      return false;
    }
    final previous = state.rules;
    emit(state.copyWith(rules: next, clearError: true));
    try {
      await _rules.save(next);
    } on Object catch (e, s) {
      AppLogger.e('rules save failed', e, s);
      emit(state.copyWith(rules: previous, error: saveFailed));
      return false;
    }
    await resync();
    return true;
  }

  /// One-shot, re-armed on every resync — not a ticker. Keeps statuses and
  /// the pushed horizon fresh while the app is alive; native's `ruleBoundary`
  /// covers the backgrounded-but-alive case, the next resume covers the rest.
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

  @override
  Future<void> close() {
    _timer?.cancel();
    _boundary?.cancel();
    return super.close();
  }
}
