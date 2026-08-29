import 'dart:convert';

import 'package:detoxo/core/storage/local_store.dart';
import 'package:detoxo/core/utils/app_logger.dart';
import 'package:detoxo/features/limits/unblock/domain/entities/bypass_config.dart';
import 'package:detoxo/features/limits/unblock/domain/entities/bypass_entry.dart';
import 'package:detoxo/features/limits/unblock/domain/repositories/unblock_repositories.dart';

/// `{config, entries: [...]}` under [StoreKeys.bypassLedger].
///
/// An absent record means "nothing spent, defaults apply" — every reader has to
/// work on a fresh install and on an upgrade from a build that never wrote it.
class BypassLedgerRepositoryImpl implements BypassLedgerRepository {
  BypassLedgerRepositoryImpl(this._store);

  final LocalStore _store;

  /// A corrupt blob THROWS. Deliberately not a silent default: reading an
  /// unparseable ledger as empty would hand out a fresh quota every time, which
  /// turns a corrupt write into an unlimited-override bug.
  @override
  Future<BypassLedger> load() async {
    final raw = _store.read(StoreKeys.bypassLedger);
    if (raw == null) return const BypassLedger();
    final doc = jsonDecode(raw) as Map<String, dynamic>;
    final cfg = doc['config'];
    final list = doc['entries'];
    final entries = <BypassEntry>[];
    if (list is List) {
      for (final e in list) {
        final BypassEntry? entry;
        try {
          entry = e is Map
              ? BypassEntry.fromJson(Map<String, dynamic>.from(e))
              : null;
        } on Object catch (err, s) {
          AppLogger.e('bypass ledger: dropped an unreadable entry', err, s);
          continue;
        }
        if (entry == null) {
          AppLogger.w('bypass ledger: dropped an entry with an unknown kind');
          continue;
        }
        entries.add(entry);
      }
    }
    return BypassLedger(
      config: cfg is Map
          ? BypassConfig.fromJson(Map<String, dynamic>.from(cfg))
          : BypassConfig.defaults,
      entries: entries,
    );
  }

  @override
  Future<void> save(BypassLedger ledger) => _store.write(
    StoreKeys.bypassLedger,
    jsonEncode({
      'config': ledger.config.toJson(),
      'entries': [for (final e in ledger.entries) e.toJson()],
    }),
  );
}
