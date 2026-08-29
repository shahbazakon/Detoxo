import 'package:detoxo/features/limits/rules/domain/entities/rule.dart';

/// What the editor route receives via `state.extra`: the kind of a new rule,
/// or an existing rule to edit (its kind is fixed).
///
/// Domain, not presentation, because it carries only domain types and other
/// features push the editor with it — the insights screen's "set a limit for
/// this app" row (EVO-033) among them. Living in `presentation/` would have
/// made that a feature-boundary violation.
class RuleEditorArgs {
  const RuleEditorArgs({required this.kind, this.rule});

  final RuleKind kind;
  final Rule? rule;
}
