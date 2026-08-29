import 'package:detoxo/features/onboarding/domain/entities/onboarding_progress.dart';

/// The first run's resume point. Deliberately does NOT hold a "finished" flag:
/// completion is `AppSettings.onboarded`, so an install that predates this
/// record is never re-onboarded just because the record is missing.
abstract interface class OnboardingRepository {
  /// Never throws and never returns null — a missing or corrupt record is a
  /// fresh start, because the alternative is a first-run screen that crashes
  /// with no way past it.
  Future<OnboardingProgress> load();

  Future<void> save(OnboardingProgress progress);

  /// Drops the record once onboarding completes: it is resume state, and a
  /// stale one would survive "Reset app data" ordering quirks.
  Future<void> clear();
}
