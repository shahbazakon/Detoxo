import 'dart:convert';

import 'package:detoxo/core/storage/local_store.dart';
import 'package:detoxo/features/limits/web_blocker/domain/entities/web_block_entry.dart';
import 'package:detoxo/features/limits/web_blocker/domain/repositories/web_block_repository.dart';

/// Website blocklist persistence (JSON list in [LocalStore]).
class WebBlockRepositoryImpl implements WebBlockRepository {
  WebBlockRepositoryImpl(this._store);

  final LocalStore _store;

  @override
  Future<List<WebBlockEntry>> load() async {
    final raw = _store.read(StoreKeys.webBlocklist);
    if (raw == null) return const [];
    // A corrupt blob THROWS (no silent [] fallback): syncWebBlocklist must
    // abort rather than push an empty list, which native would honor as an
    // intentional clear and wipe its last-good copy. The screen surfaces the
    // error via the cubit's load() catch; a user re-add overwrites the blob.
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => WebBlockEntry.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<void> save(List<WebBlockEntry> entries) async {
    await _store.write(
      StoreKeys.webBlocklist,
      jsonEncode(entries.map((e) => e.toJson()).toList()),
    );
  }
}
