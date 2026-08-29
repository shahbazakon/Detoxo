import 'dart:convert';

import 'package:detoxo/core/storage/local_store.dart';
import 'package:detoxo/core/utils/app_logger.dart';
import 'package:detoxo/features/limits/unblock/domain/entities/temporary_unblock.dart';
import 'package:detoxo/features/limits/unblock/domain/repositories/unblock_repositories.dart';
import 'package:detoxo/features/limits/unblock/domain/usecases/unblock_quota.dart';
import 'package:detoxo/features/limits/web_blocker/domain/entities/popular_site.dart';

/// One-time migration for M8's wire-contract change: a per-site pause that was
/// running when the user upgraded becomes a `WEBSITE` grant.
///
/// Reads the RAW `web_blocklist` blob rather than going through
/// `WebBlockRepository`, because `WebBlockEntry.pausedUntil` no longer exists —
/// the parsed entity would have already dropped the field this needs. The blob
/// is then rewritten without it, so the migration is idempotent and cannot run
/// twice on the same pause.
///
/// Silent and best-effort: a user with no live pause (nearly everyone) pays one
/// string read at bootstrap, and any failure just means the pause lapses early,
/// which is the fail-safe direction.
Future<void> migrateWebPauses(
  LocalStore store,
  TemporaryUnblockRepository grants, {
  DateTime Function() now = DateTime.now,
}) async {
  try {
    final raw = store.read(StoreKeys.webBlocklist);
    if (raw == null || !raw.contains('pausedUntil')) return;
    final list = jsonDecode(raw) as List<dynamic>;
    final nowMs = now().millisecondsSinceEpoch;
    final migrated = <TemporaryUnblock>[];
    var touched = false;
    for (final e in list) {
      if (e is! Map) continue;
      final row = Map<String, dynamic>.from(e);
      final until = row.remove('pausedUntil');
      if (until == null) continue;
      touched = true;
      final endMs = until is num ? until.toInt() : 0;
      final pattern = (row['pattern'] as String? ?? '').trim().toLowerCase();
      if (endMs <= nowMs || pattern.isEmpty || row['enabled'] == false) {
        continue;
      }
      // A pattern is a valid host, and native matches a grant against the
      // visited host by suffix — so one grant per pattern reproduces exactly
      // what the pause covered. Aliases carried the primary's pause window
      // (`syncWebBlocklist` duplicated it), so they each need their own row.
      for (final id in {pattern, ...PopularSites.aliasesFor(pattern)}) {
        migrated.add(
          TemporaryUnblock(
            targetType: UnblockTargetType.website,
            targetId: id,
            startMs: nowMs,
            endMs: endMs,
            source: UnblockSource.blocklistRow,
          ),
        );
      }
    }
    if (!touched) return;
    if (migrated.isNotEmpty) {
      final existing = await grants.load();
      await grants.save(UnblockQuota.prune([...migrated, ...existing], nowMs));
    }
    await store.write(
      StoreKeys.webBlocklist,
      jsonEncode([
        for (final e in list)
          if (e is Map) (Map<String, dynamic>.from(e)..remove('pausedUntil')),
      ]),
    );
    AppLogger.d(
      'web pause migration: ${migrated.length} grant(s) carried over',
    );
  } on Object catch (e, s) {
    AppLogger.e('web pause migration failed', e, s);
  }
}
