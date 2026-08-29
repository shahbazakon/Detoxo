// limits feature — public domain (entities + repository contracts).
// Other features may import ONLY this barrel; never reach into data/ or presentation/ internals.

export 'package:detoxo/features/limits/app_blocker/domain/app_block_sync.dart';
export 'package:detoxo/features/limits/app_blocker/domain/entities/app_block_entry.dart';
export 'package:detoxo/features/limits/app_blocker/domain/repositories/app_block_repository.dart';
export 'package:detoxo/features/limits/daily_limit/domain/entities/daily_limit.dart';
export 'package:detoxo/features/limits/daily_limit/domain/repositories/daily_limit_repository.dart';
// Provided app-wide in `main.dart` alongside the rules cubit below; exported so
// splash's post-wipe reload and onboarding reach them through the barrel.
export 'package:detoxo/features/limits/daily_limit/presentation/daily_limit_cubit.dart';
export 'package:detoxo/features/limits/rules/domain/entities/rule.dart';
export 'package:detoxo/features/limits/rules/domain/entities/rule_editor_args.dart';
export 'package:detoxo/features/limits/rules/domain/entities/rule_preset.dart';
export 'package:detoxo/features/limits/rules/domain/entities/rule_snapshot.dart';
export 'package:detoxo/features/limits/rules/domain/repositories/rule_repository.dart';
export 'package:detoxo/features/limits/rules/domain/rule_sync.dart';
export 'package:detoxo/features/limits/rules/domain/usecases/lock_guard.dart';
export 'package:detoxo/features/limits/rules/domain/usecases/resolve_snapshot.dart';
export 'package:detoxo/features/limits/rules/domain/usecases/rule_calendar.dart';
export 'package:detoxo/features/limits/rules/domain/usecases/rule_summary.dart';
// The rules cubit is provided app-wide in `main.dart` (the content_counter
// precedent), so the dashboard card and the resume sync reach it through here.
export 'package:detoxo/features/limits/rules/presentation/rules_cubit.dart';
export 'package:detoxo/features/limits/streak/domain/entities/streak.dart';
export 'package:detoxo/features/limits/streak/domain/repositories/streak_repository.dart';
export 'package:detoxo/features/limits/streak/presentation/streak_cubit.dart';
// M8 — per-target unblocks and the override quota. The cubit is provided
// app-wide in `main.dart` (the rules / daily-limit precedent), so the blocklist
// screens, the rules screen and the resume sync reach it through here.
export 'package:detoxo/features/limits/unblock/domain/entities/bypass_config.dart';
export 'package:detoxo/features/limits/unblock/domain/entities/bypass_entry.dart';
export 'package:detoxo/features/limits/unblock/domain/entities/temporary_unblock.dart';
export 'package:detoxo/features/limits/unblock/domain/migrate_web_pauses.dart';
export 'package:detoxo/features/limits/unblock/domain/repositories/unblock_repositories.dart';
export 'package:detoxo/features/limits/unblock/domain/unblock_sync.dart';
export 'package:detoxo/features/limits/unblock/domain/usecases/unblock_quota.dart';
export 'package:detoxo/features/limits/unblock/presentation/unblock_cubit.dart';
export 'package:detoxo/features/limits/unblock/presentation/widgets/active_unblocks_card.dart';
export 'package:detoxo/features/limits/unblock/presentation/widgets/override_history_card.dart';
export 'package:detoxo/features/limits/unblock/presentation/widgets/unblock_duration_sheet.dart';
export 'package:detoxo/features/limits/web_blocker/domain/entities/web_block_entry.dart';
export 'package:detoxo/features/limits/web_blocker/domain/repositories/web_block_repository.dart';
export 'package:detoxo/features/limits/web_blocker/domain/web_block_sync.dart';
