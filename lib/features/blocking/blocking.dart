// blocking feature — public domain (entities + repository contracts), plus the
// block screen's embeddable surface (cubit + preview) so the Appearance hub can
// host it through this barrel — the content_counter.dart precedent. The editor
// screen is routed, not embedded, so the router imports it directly.
// Other features may import ONLY this barrel; never reach into data/ or presentation/ internals.

export 'package:detoxo/features/blocking/block_screen/domain/entities/block_screen_copy.dart';
export 'package:detoxo/features/blocking/block_screen/domain/entities/block_screen_payload.dart';
export 'package:detoxo/features/blocking/block_screen/domain/entities/block_screen_style.dart';
export 'package:detoxo/features/blocking/block_screen/domain/repositories/block_screen_repository.dart';
export 'package:detoxo/features/blocking/block_screen/presentation/block_screen_style_cubit.dart';
export 'package:detoxo/features/blocking/block_screen/presentation/widgets/block_screen_preview.dart';
// Provided app-wide in `main.dart` (the limits.dart precedent), so the features
// that read app settings or the blockable-target list reach them through here
// instead of into presentation/. Exporting these cleared five grandfathered
// entries from tool/boundaries_baseline.txt.
export 'package:detoxo/features/blocking/blocklist/presentation/targets_cubit.dart';
export 'package:detoxo/features/blocking/blocklist/presentation/widgets/block_app_tile.dart';
export 'package:detoxo/features/blocking/plans/domain/entities/mindful_quote.dart';
export 'package:detoxo/features/blocking/plans/domain/entities/sessions.dart';
export 'package:detoxo/features/blocking/plans/domain/repositories/content_repository.dart';
export 'package:detoxo/features/blocking/shared/domain/entities/app_notice.dart';
export 'package:detoxo/features/blocking/shared/domain/entities/app_settings.dart';
export 'package:detoxo/features/blocking/shared/domain/entities/block_target.dart';
export 'package:detoxo/features/blocking/shared/domain/entities/engine_event.dart';
export 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
// The boot/resume nudge-config sync + its derived watch list — the
// limits.dart precedent, where every sync helper is reached through the barrel.
export 'package:detoxo/features/blocking/shared/domain/nudge_sync.dart';
export 'package:detoxo/features/blocking/shared/domain/repositories/blocking_repositories.dart';
export 'package:detoxo/features/blocking/shared/presentation/settings_cubit.dart';
