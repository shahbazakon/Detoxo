import 'dart:convert';

import 'package:detoxo/core/storage/local_store.dart';
import 'package:detoxo/core/utils/app_logger.dart';
import 'package:detoxo/features/onboarding/domain/entities/onboarding_progress.dart';
import 'package:detoxo/features/onboarding/domain/repositories/onboarding_repository.dart';

/// Persists the first-run record as JSON in [LocalStore], one write per answer.
///
/// No in-memory cache, unlike `SettingsRepositoryImpl`: the cubit already holds
/// the live value, and a cache here would only be a second copy to keep honest.
class OnboardingRepositoryImpl implements OnboardingRepository {
  OnboardingRepositoryImpl(this._store);

  final LocalStore _store;

  @override
  Future<OnboardingProgress> load() async {
    final raw = _store.read(StoreKeys.onboardingProgress);
    if (raw == null) return const OnboardingProgress();
    try {
      return OnboardingProgress.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (e) {
      // Broad catch: a bad cast throws TypeError, not Exception. A corrupt
      // record must restart onboarding, never strand the launch on a crash.
      AppLogger.e('onboarding progress unreadable — restarting first run', e);
      return const OnboardingProgress();
    }
  }

  @override
  Future<void> save(OnboardingProgress progress) =>
      _store.write(StoreKeys.onboardingProgress, jsonEncode(progress.toJson()));

  @override
  Future<void> clear() => _store.delete(StoreKeys.onboardingProgress);
}
