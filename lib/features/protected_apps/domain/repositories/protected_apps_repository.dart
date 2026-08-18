import 'package:detoxo/features/protected_apps/domain/entities/protected_app.dart';

/// Persists the user's own protected-app additions. Catalog apps are protected
/// implicitly (always pushed to the engine) and are never stored here.
abstract interface class ProtectedAppsRepository {
  Future<List<ProtectedApp>> load();

  Future<void> save(List<ProtectedApp> apps);
}
