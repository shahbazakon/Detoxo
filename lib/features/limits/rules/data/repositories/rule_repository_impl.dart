import 'dart:convert';

import 'package:detoxo/core/storage/local_store.dart';
import 'package:detoxo/core/utils/app_logger.dart';
import 'package:detoxo/features/limits/rules/domain/entities/rule.dart';
import 'package:detoxo/features/limits/rules/domain/repositories/rule_repository.dart';

/// JSON list under [StoreKeys.rules].
class RuleRepositoryImpl implements RuleRepository {
  RuleRepositoryImpl(this._store);

  final LocalStore _store;

  /// A corrupt blob THROWS (no silent `[]`): `syncRules` must abort rather
  /// than push an empty snapshot, which native would honour as a clear. A
  /// single unreadable document — an unknown `kind`, a non-object element, or
  /// anything that throws while parsing — is dropped on its own (logged) so a
  /// newer build's rule cannot take the whole list down with it.
  @override
  Future<List<Rule>> load() async {
    final raw = _store.read(StoreKeys.rules);
    if (raw == null) return const [];
    final list = jsonDecode(raw) as List<dynamic>;
    final out = <Rule>[];
    for (final e in list) {
      final Rule? rule;
      try {
        rule = e is Map ? Rule.fromJson(Map<String, dynamic>.from(e)) : null;
      } on Object catch (err, s) {
        AppLogger.e('rules: dropped an unreadable document', err, s);
        continue;
      }
      if (rule == null) {
        AppLogger.w('rules: dropped a document with an unknown kind');
        continue;
      }
      out.add(rule);
    }
    return out;
  }

  @override
  Future<void> save(List<Rule> rules) => _store.write(
    StoreKeys.rules,
    jsonEncode([for (final r in rules) r.toJson()]),
  );
}
