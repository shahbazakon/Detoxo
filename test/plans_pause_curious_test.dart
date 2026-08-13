import 'dart:async';

import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/features/blocking/plans/data/repositories/content_repository_impl.dart';
import 'package:detoxo/features/blocking/plans/domain/entities/conscious_state.dart';
import 'package:detoxo/features/blocking/plans/domain/entities/emoji_band.dart';
import 'package:detoxo/features/blocking/plans/domain/entities/reel_session_state.dart';
import 'package:detoxo/features/blocking/plans/domain/entities/sessions.dart';
import 'package:detoxo/features/blocking/plans/presentation/widgets/animated_digit_timer.dart';
import 'package:detoxo/features/blocking/plans/presentation/widgets/animated_emoji.dart';
import 'package:detoxo/features/blocking/plans/presentation/widgets/countdown_ring.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/app_settings.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/engine_event.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
import 'package:detoxo/features/blocking/shared/domain/repositories/blocking_repositories.dart';
import 'package:detoxo/features/blocking/shared/presentation/settings_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EmojiAnimation.fromWire', () {
    test('parses every wire token case-insensitively', () {
      expect(EmojiAnimation.fromWire('BREATHING'), EmojiAnimation.breathing);
      expect(EmojiAnimation.fromWire('shake'), EmojiAnimation.shake);
      expect(EmojiAnimation.fromWire('FLY'), EmojiAnimation.fly);
    });
    test('falls back to breathing on unknown/null', () {
      expect(EmojiAnimation.fromWire('nope'), EmojiAnimation.breathing);
      expect(EmojiAnimation.fromWire(null), EmojiAnimation.breathing);
    });
  });

  group('EmojiItem / EmojiPlacement matching', () {
    const a = EmojiItem(
      id: 'a',
      rangeMin: 0,
      rangeMax: 2,
      emoji: '✨',
      title: 'Demure',
      description: '',
      animation: EmojiAnimation.breathing,
    );
    const b = EmojiItem(
      id: 'b',
      rangeMin: 3,
      rangeMax: 5,
      emoji: '👀',
      title: 'Side Eye',
      description: '',
      animation: EmojiAnimation.scanning,
    );
    const placement = EmojiPlacement(
      placementId: 'P',
      enabled: true,
      set: EmojiSet(setId: 's', placementId: 'P', enabled: true, items: [a, b]),
    );

    test('covers is inclusive at both bounds', () {
      expect(a.covers(0), isTrue);
      expect(a.covers(2), isTrue);
      expect(a.covers(3), isFalse);
    });
    test('itemFor picks the band whose range covers the value', () {
      expect(placement.itemFor(1)?.id, 'a');
      expect(placement.itemFor(4)?.id, 'b');
      expect(placement.itemFor(99), isNull);
    });
    test('disabled set yields nothing', () {
      const disabled = EmojiPlacement(
        placementId: 'P',
        enabled: true,
        set: EmojiSet(setId: 's', placementId: 'P', enabled: false, items: [a]),
      );
      expect(disabled.itemFor(0), isNull);
      expect(disabled.isUsable, isFalse);
    });
    test('fromBundle reads the first set', () {
      final p = EmojiPlacement.fromBundle({
        'emojiSets': [
          {
            'setId': 's1',
            'placementId': 'EMOJI_CURIOUS_PLAN',
            'enabled': true,
            'emojis': [
              {
                'emojiId': 'e1',
                'rangeMin': 0,
                'rangeMax': 5,
                'emoji': '🎯',
                'title': 'Stay Sharp',
                'description': 'x',
                'animation': 'BREATHING',
              },
            ],
          },
        ],
      });
      expect(p.isUsable, isTrue);
      expect(p.placementId, 'EMOJI_CURIOUS_PLAN');
      expect(p.itemFor(3)?.title, 'Stay Sharp');
    });
    test('fromBundle on empty json is a safe disabled placement', () {
      final p = EmojiPlacement.fromBundle(const {});
      expect(p.isUsable, isFalse);
    });
  });

  group('PauseSession helpers', () {
    final start = DateTime(2026, 1, 1, 10);

    test('phaseAt: active in window then idle (no wind-down)', () {
      final s = PauseSession(
        startedAt: start,
        pauseDuration: const Duration(minutes: 5),
        cooldownDuration: Duration.zero,
        planToResume: BlockingPlan.blockAll,
      );
      expect(
        s.phaseAt(start.add(const Duration(minutes: 2))),
        SessionPhase.active,
      );
      expect(
        s.phaseAt(start.add(const Duration(minutes: 6))),
        SessionPhase.idle,
      );
    });
  });

  group('ConsciousState', () {
    test('fromMap parses native snapshot', () {
      final s = ConsciousState.fromMap(const {
        'bankMs': 120000,
        'maxBankMs': 600000,
        'watching': true,
        'blocked': false,
        'active': true,
      });
      expect(s.banked, const Duration(minutes: 2));
      expect(s.maxBank, const Duration(minutes: 10));
      expect(s.watching, isTrue);
      expect(s.hasAllowance, isTrue);
      expect(s.progress, closeTo(0.2, 0.001));
    });

    test('empty bank → blocked, no allowance, zero progress', () {
      const s = ConsciousState(active: true, blocked: true);
      expect(s.hasAllowance, isFalse);
      expect(s.progress, 0);
    });

    test('progress is clamped and safe when maxBank is zero', () {
      const s = ConsciousState(bankMs: 5, maxBankMs: 0);
      expect(s.progress, 0);
    });
  });

  group('AppSettings derived enforcement (pause-only)', () {
    final now = DateTime(2026, 1, 1, 12);

    AppSettings pause({required BlockingPlan plan}) => AppSettings(
      activePlan: plan,
      pauseSession: PauseSession(
        startedAt: now,
        pauseDuration: const Duration(minutes: 5),
        cooldownDuration: Duration.zero,
        planToResume: BlockingPlan.blockAll,
      ),
    );

    test('pause window suspends all blocking until the window end', () {
      final s = pause(plan: BlockingPlan.blockAll);
      final mid = now.add(const Duration(minutes: 2));
      expect(s.isPaused(mid), isTrue);
      expect(s.isPauseContractLive(mid), isTrue);
      expect(s.nativePauseUntil(mid), now.add(const Duration(minutes: 5)));
      expect(s.effectiveNativePlan(mid), BlockingPlan.blockAll);
    });

    test('after the window, blocking resumes with no suspension', () {
      final s = pause(plan: BlockingPlan.blockAll);
      final after = now.add(const Duration(minutes: 6));
      expect(s.isPauseContractLive(after), isFalse);
      expect(s.nativePauseUntil(after), isNull);
      expect(s.effectiveNativePlan(after), BlockingPlan.blockAll);
    });

    test('Conscious pushes through unchanged — native owns the bank', () {
      const s = AppSettings(activePlan: BlockingPlan.curious);
      expect(s.nativePauseUntil(), isNull);
      expect(s.effectiveNativePlan(), BlockingPlan.curious);
    });

    test('legacy persisted PAUSED plan migrates to Block All on load', () {
      // Old builds stored activePlan='PAUSED' while a pause ran; the new model
      // never does, so a stale value must collapse to Block All (no phantom UI).
      final back = AppSettings.fromJson(const {'activePlan': 'PAUSED'});
      expect(back.activePlan, BlockingPlan.blockAll);
      expect(back.effectiveNativePlan(), BlockingPlan.blockAll);
    });

    test('JSON round-trips the pause session', () {
      final s = AppSettings(
        pauseSession: PauseSession(
          startedAt: now,
          pauseDuration: const Duration(minutes: 5),
          cooldownDuration: Duration.zero,
          planToResume: BlockingPlan.blockAll,
        ),
      );
      final back = AppSettings.fromJson(s.toJson());
      expect(back.pauseSession, s.pauseSession);
      expect(back.activePlan, BlockingPlan.blockAll);
    });
  });

  group('SettingsCubit transitions', () {
    late _FakeSettingsRepo settings;
    late _FakeEngineRepo engine;
    late SettingsCubit cubit;

    setUp(() {
      settings = _FakeSettingsRepo(const AppSettings());
      engine = _FakeEngineRepo();
      cubit = SettingsCubit(settings, engine);
    });

    tearDown(() async {
      await cubit.close(); // cancels the pause ticker + reel subscription
      await engine.reelController.close();
    });

    test('startPause sets Block All with a live pause window', () async {
      await cubit.startPause(pause: const Duration(minutes: 5));
      expect(cubit.state.activePlan, BlockingPlan.blockAll);
      expect(cubit.state.pauseSession, isNotNull);
      expect(cubit.state.isPaused(), isTrue);
      expect(engine.pushed, isNotEmpty);
    });

    test('setPlan records the base mode; startPause resumes into it', () async {
      await cubit.enterConscious(); // base = Conscious
      expect(cubit.state.baseMode, BlockingPlan.curious);
      await cubit.startPause(pause: const Duration(minutes: 5));
      expect(cubit.state.activePlan, BlockingPlan.curious);
      expect(cubit.state.pauseSession?.planToResume, BlockingPlan.curious);
    });

    test(
      'One Reel auto-reverts to the base once the allowance is spent',
      () async {
        await cubit.setOneReel(count: 1); // base stays Block All
        expect(cubit.state.activePlan, BlockingPlan.oneReel);

        // An allowed reel (blocked == false) must NOT revert.
        engine.emitReel(const ReelSessionState(consumed: 1, active: true));
        await pumpEventQueue();
        expect(cubit.state.activePlan, BlockingPlan.oneReel);

        // The block past the allowance reverts to the base.
        engine.emitReel(
          const ReelSessionState(consumed: 1, active: true, blocked: true),
        );
        await pumpEventQueue();
        expect(cubit.state.activePlan, BlockingPlan.blockAll);
      },
    );

    test('Unblock auto-reverts to a Conscious base', () async {
      await cubit.enterConscious(); // base = Conscious
      await cubit.setOneReel(count: 5); // Unblock 5
      expect(cubit.state.activePlan, BlockingPlan.oneReel);

      engine.emitReel(
        const ReelSessionState(
          consumed: 5,
          allowance: 5,
          active: true,
          blocked: true,
        ),
      );
      await pumpEventQueue();
      expect(cubit.state.activePlan, BlockingPlan.curious);
    });

    test('resumeNow ends the pause and blocks immediately', () async {
      await cubit.startPause(pause: const Duration(minutes: 5));
      await cubit.resumeNow();
      expect(cubit.state.pauseSession, isNull);
      expect(cubit.state.activePlan, BlockingPlan.blockAll);
    });

    test('enterConscious then stopConscious flips the plan', () async {
      await cubit.enterConscious();
      expect(cubit.state.activePlan, BlockingPlan.curious);
      expect(cubit.state.pauseSession, isNull);
      await cubit.stopConscious();
      expect(cubit.state.activePlan, BlockingPlan.blockAll);
    });

    test('setPlan clears a live pause', () async {
      await cubit.startPause(pause: const Duration(minutes: 5));
      await cubit.setPlan(BlockingPlan.curious);
      expect(cubit.state.activePlan, BlockingPlan.curious);
      expect(cubit.state.pauseSession, isNull);
    });
  });

  group('Mindful Countdown widgets', () {
    testWidgets('AnimatedEmoji builds for all 14 animations', (tester) async {
      for (final anim in EmojiAnimation.values) {
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: AnimatedEmoji(emoji: '🎯', animation: anim),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 16));
        expect(find.text('🎯'), findsOneWidget, reason: 'anim=$anim');
      }
      await tester.pumpWidget(const SizedBox()); // dispose tickers
    });

    testWidgets('AnimatedDigitTimer renders mm:ss', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: AnimatedDigitTimer(remaining: Duration(seconds: 125)),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('0'), findsWidgets); // 02:05 → has digit cells
      expect(find.text('2'), findsWidgets);
      expect(find.text(':'), findsOneWidget);
    });

    testWidgets('CountdownRing renders its centred digits and emoji', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: const Scaffold(
            body: Center(
              child: CountdownRing(
                progress: 0.8,
                center: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AnimatedEmoji(
                      emoji: '🎯',
                      animation: EmojiAnimation.breathing,
                      size: 30,
                    ),
                    AnimatedDigitTimer(
                      remaining: Duration(minutes: 4, seconds: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 16));
      expect(find.text('🎯'), findsOneWidget);
      expect(find.text(':'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('ContentRepository emoji bundle (real assets)', () {
    testWidgets('curious band bucket 0 is "Stay Sharp"', (tester) async {
      final repo = ContentRepositoryImpl();
      final items = await repo.emojiFor(EmojiPlacementId.curiousPlan, 0);
      expect(items, isNotEmpty);
      expect(items.first.title, 'Stay Sharp');
    });
  });
}

class _FakeSettingsRepo implements SettingsRepository {
  _FakeSettingsRepo(this._initial);
  final AppSettings _initial;
  AppSettings? saved;

  @override
  Future<AppSettings> load() async => _initial;

  @override
  Future<void> save(AppSettings settings) async => saved = settings;

  @override
  Stream<AppSettings> watch() => const Stream.empty();
}

class _FakeEngineRepo implements EngineRepository {
  final List<AppSettings> pushed = [];

  @override
  Future<void> pushSettings(AppSettings settings) async => pushed.add(settings);

  @override
  Future<void> pushConfig(String configJson) async {}

  @override
  Future<void> pushWebBlocklist(String json) async {}

  @override
  Future<void> pushProtectedApps(List<String> packages) async {}

  @override
  Stream<ServiceSnapshot> statusStream() => const Stream.empty();

  @override
  Stream<BlockEvent> blockStream() => const Stream.empty();

  @override
  Stream<ConsciousState> consciousStream() => const Stream.empty();

  @override
  Future<ConsciousState> consciousCurrent() async => const ConsciousState();

  @override
  Future<void> resetConsciousBank() async {}

  final StreamController<ReelSessionState> reelController =
      StreamController<ReelSessionState>.broadcast();

  /// Push a reel-session update to the cubit's subscription (test helper).
  void emitReel(ReelSessionState state) => reelController.add(state);

  @override
  Stream<ReelSessionState> reelSessionStream() => reelController.stream;

  @override
  Future<void> armReelSession(int count) async {}

  @override
  Future<ReelSessionState> reelSessionCurrent() async =>
      const ReelSessionState();

  @override
  Future<ServiceSnapshot> currentStatus() async => const ServiceSnapshot();

  @override
  Future<void> performBack() async {}

  @override
  Future<void> killApp(String packageName) async {}

  @override
  Future<void> lockScreen() async {}

  @override
  Future<Set<String>?> installedPackages() async => null;
}
