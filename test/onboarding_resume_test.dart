import 'dart:async';
import 'dart:convert';

import 'package:detoxo/core/storage/local_store.dart';
import 'package:detoxo/features/onboarding/data/repositories/onboarding_repository_impl.dart';
import 'package:detoxo/features/onboarding/domain/entities/onboarding_progress.dart';
import 'package:detoxo/features/onboarding/domain/onboarding_script.dart';
import 'package:detoxo/features/onboarding/domain/repositories/onboarding_repository.dart';
import 'package:detoxo/features/onboarding/presentation/onboarding_cubit.dart';
import 'package:flutter_test/flutter_test.dart';

/// In-memory [LocalStore] (no Hive / secure storage) for repository tests.
class _FakeStore implements LocalStore {
  final Map<String, String> plain = {};
  final Map<String, String> secrets = {};

  @override
  String? read(String key) => plain[key];
  @override
  Future<void> write(String key, String value) async => plain[key] = value;
  @override
  Future<void> delete(String key) async => plain.remove(key);
  @override
  Future<String?> readSecret(String key) async => secrets[key];
  @override
  Future<void> writeSecret(String key, String value) async =>
      secrets[key] = value;
  @override
  Future<void> deleteSecret(String key) async => secrets.remove(key);
  @override
  Future<void> clearAll() async {
    plain.clear();
    secrets.clear();
  }
}

/// Delegates to the real repository but holds `save` open until [_until]
/// completes, so a test can observe the store and the cubit state mid-write.
class _GatedRepo implements OnboardingRepository {
  _GatedRepo(this._inner, this._until);

  final OnboardingRepository _inner;
  final Future<void> _until;

  @override
  Future<OnboardingProgress> load() => _inner.load();

  @override
  Future<void> save(OnboardingProgress progress) async {
    await _inner.save(progress);
    await _until;
  }

  @override
  Future<void> clear() => _inner.clear();
}

void main() {
  late _FakeStore store;
  late OnboardingRepositoryImpl repo;

  setUp(() {
    store = _FakeStore();
    repo = OnboardingRepositoryImpl(store);
  });

  /// A fresh cubit over the same store — i.e. the app was killed and relaunched.
  Future<OnboardingCubit> relaunch() async {
    final cubit = OnboardingCubit(repo);
    await cubit.load();
    return cubit;
  }

  Map<String, dynamic> stored() =>
      jsonDecode(store.plain[StoreKeys.onboardingProgress]!)
          as Map<String, dynamic>;

  group('resume', () {
    test(
      'a kill at every step relaunches at that step, never at the start',
      () {
        // The whole point of the machine: no step is a restart.
        return Future.forEach(OnboardingStepId.visible, (step) async {
          store.plain.clear();
          final first = OnboardingCubit(repo);
          await first.load();
          await first.advance(step);
          await first.close();

          final resumed = await relaunch();
          expect(
            resumed.state.step,
            step,
            reason: 'killed on $step, should resume on $step',
          );
          await resumed.close();
        });
      },
    );

    test(
      'a first run with no record starts at welcome, not at a crash',
      () async {
        final cubit = await relaunch();
        expect(cubit.state.step, OnboardingStepId.welcome);
        expect(cubit.state.startedAtMs, greaterThan(0));
        await cubit.close();
      },
    );

    test('a corrupt record restarts the run instead of stranding it', () async {
      store.plain[StoreKeys.onboardingProgress] = '{not json at all';
      final cubit = await relaunch();
      expect(cubit.state.step, OnboardingStepId.welcome);
      await cubit.close();
    });

    test(
      'an unknown step token from a newer build degrades to welcome',
      () async {
        store.plain[StoreKeys.onboardingProgress] = jsonEncode({
          'step': 'SOMETHING_WE_HAVE_NOT_SHIPPED',
        });
        final cubit = await relaunch();
        expect(cubit.state.step, OnboardingStepId.welcome);
        await cubit.close();
      },
    );

    test('an unknown enum token degrades to null, not to a throw', () async {
      store.plain[StoreKeys.onboardingProgress] = jsonEncode({
        'step': OnboardingStepId.survey.wire,
        'screenTimeBand': 'BETWEEN_9_AND_10H',
        'mattersMost': 'VIBES',
      });
      final cubit = await relaunch();
      expect(cubit.state.step, OnboardingStepId.survey);
      expect(cubit.state.band, isNull);
      expect(cubit.state.mattersMost, isNull);
      await cubit.close();
    });
  });

  group('per-answer writes', () {
    test('each answer hits the store when given, not at the end', () async {
      final cubit = await relaunch();

      await cubit.answer(fieldName, 'Sam');
      expect(stored()['name'], 'Sam');

      await cubit.answer(fieldBand, ScreenTimeBand.between3And4h.wire);
      expect(stored()['screenTimeBand'], 'BETWEEN_3_AND_4H');

      await cubit.answer(fieldMattersMost, MattersMost.sleep.wire);
      expect(stored()['mattersMost'], 'SLEEP');

      // Abandoning here must not lose any of the three.
      await cubit.close();
      final resumed = await relaunch();
      expect(resumed.state.name, 'Sam');
      expect(resumed.state.band, ScreenTimeBand.between3And4h);
      expect(resumed.state.mattersMost, MattersMost.sleep);
      await resumed.close();
    });

    test('the step is persisted before it is emitted', () async {
      // Hold the write open, then look at both sides mid-flight. A stream
      // listener cannot see this: emits are delivered on a microtask, so by the
      // time one runs the write has always finished either way.
      final gate = Completer<void>();
      final gated = _GatedRepo(repo, gate.future);
      final cubit = OnboardingCubit(gated);
      await cubit.load();

      final pending = cubit.advance(OnboardingStepId.survey);
      await Future<void>.delayed(Duration.zero);

      // Written, not yet emitted. The reverse order would lose the step to a
      // crash here; this order replays it, which is harmless.
      expect(stored()['step'], OnboardingStepId.survey.wire);
      expect(cubit.state.step, OnboardingStepId.welcome);

      gate.complete();
      await pending;
      expect(cubit.state.step, OnboardingStepId.survey);
      await cubit.close();
    });

    test('clearing the name field clears it in the store', () async {
      final cubit = await relaunch();
      await cubit.answer(fieldName, 'Sam');
      await cubit.answer(fieldName, '   ');
      expect(cubit.state.name, isNull);
      expect(stored()['name'], isNull);
      await cubit.close();
    });

    test('an unknown script field is ignored, not thrown', () async {
      final cubit = await relaunch();
      await cubit.answer('a_field_that_does_not_exist', 'x');
      expect(
        cubit.state,
        const OnboardingProgress().copyWith(
          startedAtMs: cubit.state.startedAtMs,
        ),
      );
      await cubit.close();
    });
  });

  group('migration', () {
    test(
      'an existing install has no record, and reading one is harmless',
      () async {
        // The completion flag is `AppSettings.onboarded`, NOT this record — so an
        // upgrading user's absent record must never be a signal to re-onboard.
        // Reading it is a fresh `welcome`, and the router never asks.
        expect(store.plain.containsKey(StoreKeys.onboardingProgress), isFalse);
        final progress = await repo.load();
        expect(progress, const OnboardingProgress());
        // Load alone must not write anything back.
        expect(store.plain.containsKey(StoreKeys.onboardingProgress), isFalse);
      },
    );

    test('clear removes the record once the run is done', () async {
      await repo.save(
        const OnboardingProgress(step: OnboardingStepId.completed),
      );
      await repo.clear();
      expect(store.plain.containsKey(StoreKeys.onboardingProgress), isFalse);
    });
  });

  group('step order', () {
    test('previous/next walk the visible steps and stop at the ends', () async {
      final cubit = await relaunch();
      expect(cubit.previousStep, isNull, reason: 'welcome is the first step');
      expect(cubit.nextStep, OnboardingStepId.survey);

      await cubit.advance(OnboardingStepId.permissions);
      expect(cubit.nextStep, isNull, reason: 'permissions is the last step');
      expect(cubit.previousStep, OnboardingStepId.commitment);
      await cubit.close();
    });

    test('completed is terminal and never walked to', () {
      expect(
        OnboardingStepId.visible,
        isNot(contains(OnboardingStepId.completed)),
      );
    });
  });
}
