// permissions feature — public domain (entities + repository contracts).
// Other features may import ONLY this barrel; never reach into data/ or presentation/ internals.

export 'package:detoxo/features/permissions/domain/entities/permission_status.dart';
export 'package:detoxo/features/permissions/domain/repositories/permission_repository.dart';
// The single entry point for granting a permission (disclosure + the
// restricted-settings walkthrough + the cubit re-read). Exported so a feature's
// own Grant button reaches it instead of calling the repository directly and
// skipping the recovery flow — the blocking.dart precedent for shared surfaces.
export 'package:detoxo/features/permissions/presentation/permission_actions.dart'
    show requestPermission;
