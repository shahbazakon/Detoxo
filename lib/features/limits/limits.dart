// limits feature — public domain (entities + repository contracts).
// Other features may import ONLY this barrel; never reach into data/ or presentation/ internals.

export 'package:detoxo/features/limits/app_blocker/domain/entities/app_block_entry.dart';
export 'package:detoxo/features/limits/app_blocker/domain/repositories/app_block_repository.dart';
export 'package:detoxo/features/limits/daily_limit/domain/entities/daily_limit.dart';
export 'package:detoxo/features/limits/daily_limit/domain/repositories/daily_limit_repository.dart';
export 'package:detoxo/features/limits/streak/domain/entities/streak.dart';
export 'package:detoxo/features/limits/streak/domain/repositories/streak_repository.dart';
export 'package:detoxo/features/limits/web_blocker/domain/entities/web_block_entry.dart';
export 'package:detoxo/features/limits/web_blocker/domain/repositories/web_block_repository.dart';
export 'package:detoxo/features/limits/web_blocker/domain/web_block_sync.dart';
