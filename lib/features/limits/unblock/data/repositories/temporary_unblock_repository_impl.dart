import 'dart:convert';

import 'package:detoxo/core/storage/local_store.dart';
import 'package:detoxo/core/utils/app_logger.dart';
import 'package:detoxo/features/limits/unblock/domain/entities/temporary_unblock.dart';
import 'package:detoxo/features/limits/unblock/domain/repositories/unblock_repositories.dart';

/// `{grants: [...]}` under [StoreKeys.temporaryUnblocks].
///
/// An object rather than a bare array so a later field (a per-target cooldown,
/// say) is additive — the `usage_daily` shape, not the `rules` one.
class TemporaryUnblockRepositoryImpl implements TemporaryUnblockRepository {
  TemporaryUnblockRepositoryImpl(this._store);

  final LocalStore _store;

  /// A corrupt blob THROWS (the `rules` contract): the sync must abort rather
  /// than push `[]`, which native honours as a clear — that would yank a grant
  /// out from under a user who is mid-way through using it. A single
  /// unreadable row is dropped on its own.
  @override
  Future<List<TemporaryUnblock>> load() async {
    final raw = _store.read(StoreKeys.temporaryUnblocks);
    if (raw == null) return const [];
    final doc = jsonDecode(raw) as Map<String, dynamic>;
    final list = doc['grants'];
    if (list is! List) return const [];
    final out = <TemporaryUnblock>[];
    for (final e in list) {
      final TemporaryUnblock? grant;
      try {
        grant = e is Map
            ? TemporaryUnblock.fromJson(Map<String, dynamic>.from(e))
            : null;
      } on Object catch (err, s) {
        AppLogger.e('unblocks: dropped an unreadable grant', err, s);
        continue;
      }
      if (grant == null) {
        AppLogger.w('unblocks: dropped a grant with an unusable target');
        continue;
      }
      out.add(grant);
    }
    return out;
  }

  @override
  Future<void> save(List<TemporaryUnblock> grants) => _store.write(
    StoreKeys.temporaryUnblocks,
    jsonEncode({
      'grants': [for (final g in grants) g.toJson()],
    }),
  );
}
