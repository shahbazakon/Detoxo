import 'package:detoxo/features/onboarding/domain/entities/onboarding_progress.dart';

/// How a survey question is answered.
enum QuestionKind { text, chips }

/// One survey question, as data. The walker in `survey_step.dart` renders the
/// list; **adding a question is a list edit** — no new widget, no new state
/// field, no new navigation edge. Onboarding copy churns hard before launch and
/// this is the difference between an hour and a day per change.
///
/// Deliberately non-generic: a `const` list of `AskChips<SomeEnum>` erases to
/// `dynamic` in the walker anyway, so the type parameter buys nothing and costs
/// a cast at every render.
class OnboardingQuestion {
  const OnboardingQuestion({
    required this.field,
    required this.prompt,
    required this.kind,
    this.hint,
    this.options = const [],
    this.optional = false,
  });

  /// The [OnboardingProgress] field this answer writes. Matches the wire name.
  final String field;
  final String prompt;
  final QuestionKind kind;

  /// Placeholder for [QuestionKind.text]; ignored for chips.
  final String? hint;

  /// Empty for [QuestionKind.text].
  final List<({String wire, String label})> options;

  /// A question the user may leave blank and still advance.
  final bool optional;
}

const String fieldName = 'name';
const String fieldBand = 'screenTimeBand';
const String fieldMattersMost = 'mattersMost';

/// The three things worth asking. Every answer drives something downstream:
/// the band feeds the projection maths, `mattersMost` picks the starter rule,
/// the name personalises the commitment screen.
final List<OnboardingQuestion> surveyQuestions = [
  const OnboardingQuestion(
    field: fieldName,
    prompt: 'What should we call you?',
    kind: QuestionKind.text,
    hint: 'Your first name',
    optional: true,
  ),
  OnboardingQuestion(
    field: fieldBand,
    prompt: 'How long do you spend on short-form video a day?',
    kind: QuestionKind.chips,
    options: [
      for (final b in ScreenTimeBand.values) (wire: b.wire, label: b.label),
    ],
  ),
  OnboardingQuestion(
    field: fieldMattersMost,
    prompt: 'What matters most to you right now?',
    kind: QuestionKind.chips,
    options: [
      for (final m in MattersMost.values) (wire: m.wire, label: m.label),
    ],
  ),
];
