import 'package:detoxo/features/limits/rules/domain/entities/rule.dart';

/// Persists the user's blocking rules.
abstract interface class RuleRepository {
  /// Throws on a corrupt store — the sync must abort rather than push an empty
  /// snapshot, which native would honour as an intentional clear.
  Future<List<Rule>> load();
  Future<void> save(List<Rule> rules);
}
