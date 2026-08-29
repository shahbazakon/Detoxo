// onboarding feature — the first-run screen plus the domain that outlives it:
// the persisted progress record (read by the app's starter-rule sync) and the
// survey → rule mapping.
// Other features may import ONLY this barrel; never reach into data/ or presentation/ internals.

export 'package:detoxo/features/onboarding/domain/entities/onboarding_progress.dart';
export 'package:detoxo/features/onboarding/domain/repositories/onboarding_repository.dart';
export 'package:detoxo/features/onboarding/domain/starter_rule.dart';
export 'package:detoxo/features/onboarding/presentation/onboarding_screen.dart';
