import 'dart:convert';

import 'package:detoxo/core/storage/local_store.dart';
import 'package:detoxo/core/utils/app_logger.dart';
import 'package:detoxo/features/protected_apps/domain/entities/protected_app.dart';
import 'package:detoxo/features/protected_apps/domain/repositories/protected_apps_repository.dart';

/// Manual protected-app additions persistence. Catalog protection is implicit
/// (derived, never stored), so losing this file loses nothing sensitive.
class ProtectedAppsRepositoryImpl implements ProtectedAppsRepository {
  ProtectedAppsRepositoryImpl(this._store);

  final LocalStore _store;

  @override
  Future<List<ProtectedApp>> load() async {
    final raw = _store.read(StoreKeys.protectedApps);
    if (raw == null) return const [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      final apps = <ProtectedApp>[];
      for (final entry in list) {
        // Per-entry salvage: one unreadable row must never discard the
        // user's other protections (that would fail open).
        try {
          final app = ProtectedApp.fromJson(entry as Map<String, dynamic>);
          // Early builds seeded catalog rows into storage; the catalog is
          // implicit now, so drop them (next save rewrites without them).
          if (app.source == ProtectedAppSource.manual) apps.add(app);
        } on Object catch (e) {
          AppLogger.e('skipping unreadable protected-app entry', e);
        }
      }
      return apps;
    } on Object catch (e) {
      AppLogger.e('protected apps unreadable — resetting to empty', e);
      return const [];
    }
  }

  @override
  Future<void> save(List<ProtectedApp> apps) async {
    await _store.write(
      StoreKeys.protectedApps,
      jsonEncode(apps.map((a) => a.toJson()).toList()),
    );
  }
}
