import 'package:detoxo/features/blocking/shared/domain/repositories/blocking_repositories.dart';
import 'package:detoxo/features/protected_apps/domain/entities/protected_app.dart';
import 'package:detoxo/features/protected_apps/domain/entities/protected_app_catalog.dart';
import 'package:detoxo/features/protected_apps/domain/repositories/protected_apps_repository.dart';

/// The full set pushed to the engine: the entire catalog (always protected —
/// an uninstalled package can never be foreground, and one installed later is
/// covered instantly) plus the user's enabled manual additions.
List<String> protectedPackagesFor(List<ProtectedApp> manual) => [
  for (final app in ProtectedAppCatalog.apps) app.packageName,
  for (final app in manual)
    if (app.isEnabled) app.packageName,
];

/// Boot-time protected-apps sync, called fire-and-forget from the splash
/// bootstrap so native always matches Dart — including after "Reset app data"
/// wiped Hive but not native prefs (until this runs, native *over*-protects,
/// the fail-safe direction).
Future<void> syncProtectedAppsAtBoot(
  ProtectedAppsRepository repo,
  EngineRepository engine,
) async {
  await engine.pushProtectedApps(protectedPackagesFor(await repo.load()));
}
