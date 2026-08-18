// protected_apps feature — public domain (entities + repository contracts +
// the boot-time sync helper).
// Other features may import ONLY this barrel; never reach into data/ or presentation/ internals.

export 'package:detoxo/features/protected_apps/domain/entities/protected_app.dart';
export 'package:detoxo/features/protected_apps/domain/entities/protected_app_catalog.dart';
export 'package:detoxo/features/protected_apps/domain/protected_apps_boot.dart';
export 'package:detoxo/features/protected_apps/domain/repositories/protected_apps_repository.dart';
