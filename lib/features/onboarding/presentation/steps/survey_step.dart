import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/features/onboarding/domain/entities/onboarding_progress.dart';
import 'package:detoxo/features/onboarding/domain/onboarding_script.dart';
import 'package:detoxo/features/onboarding/presentation/onboarding_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Walks [surveyQuestions] and renders whatever is in the list. All three
/// questions sit on one screen — a survey is a survey, not three page turns —
/// and each answer is written to the store the moment it is given.
class SurveyStep extends StatelessWidget {
  const SurveyStep({required this.progress, super.key});

  final OnboardingProgress progress;

  /// The answers the user must give before Next unlocks. Derived from the
  /// script, so a new required question gates the step with no other edit.
  static bool isComplete(OnboardingProgress p) => surveyQuestions
      .where((q) => !q.optional)
      .every((q) => _valueOf(p, q.field) != null);

  static String? _valueOf(OnboardingProgress p, String field) =>
      switch (field) {
        fieldName => p.name,
        fieldBand => p.band?.wire,
        fieldMattersMost => p.mattersMost?.wire,
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final cubit = context.read<OnboardingCubit>();
    return ListView(
      padding: const EdgeInsets.fromLTRB(AppSpacing.xl, 96, AppSpacing.xl, 168),
      children: [
        Text(
          'A few quick things',
          style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w800),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'Your answers stay on this device. They shape what Detoxo sets up '
          'for you.',
          style: text.bodyMedium?.copyWith(color: context.glass.onGlassMuted),
        ),
        const SizedBox(height: AppSpacing.xl),
        EntranceList(
          children: [
            for (final q in surveyQuestions)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.xl),
                child: _Question(
                  question: q,
                  value: _valueOf(progress, q.field),
                  onAnswer: (v) => cubit.answer(q.field, v),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _Question extends StatelessWidget {
  const _Question({
    required this.question,
    required this.value,
    required this.onAnswer,
  });

  final OnboardingQuestion question;
  final String? value;
  final ValueChanged<String?> onAnswer;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          question.prompt,
          style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: AppSpacing.md),
        switch (question.kind) {
          QuestionKind.text => _TextAnswer(
            hint: question.hint,
            label: question.prompt,
            initial: value,
            onAnswer: onAnswer,
          ),
          QuestionKind.chips => Wrap(
            spacing: AppSpacing.xs,
            runSpacing: AppSpacing.xs,
            children: [
              for (final o in question.options)
                AppChip(
                  label: o.label,
                  selected: value == o.wire,
                  // Single-select and never deselectable: a required question
                  // with nothing chosen is a dead Next button the user cannot
                  // explain, so re-tapping the chosen chip is a no-op.
                  onSelected: () => onAnswer(o.wire),
                ),
            ],
          ),
        },
      ],
    );
  }
}

/// Free-text answer. Writes on every edit (debounced by the field's own change
/// cadence, not by a timer) so an abandoned run keeps whatever was typed.
class _TextAnswer extends StatefulWidget {
  const _TextAnswer({
    required this.hint,
    required this.label,
    required this.initial,
    required this.onAnswer,
  });

  final String? hint;

  /// What a screen reader announces as the field's name.
  final String label;
  final String? initial;
  final ValueChanged<String?> onAnswer;

  @override
  State<_TextAnswer> createState() => _TextAnswerState();
}

class _TextAnswerState extends State<_TextAnswer> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The prompt is a sibling Text, and a collapsed decoration's hintText is
    // only announced while the field is empty — so once the user types, the
    // field would have no label at all. Name it explicitly.
    return Semantics(
      textField: true,
      label: widget.label,
      child: GlassContainer(
        enableBlur: false,
        borderRadius: AppRadius.md,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
        child: TextField(
          controller: _controller,
          // Bounded like every other input in the app (rule_editor_screen uses
          // the same 40): this is persisted and rendered into a headline.
          maxLength: 40,
          buildCounter:
              (_, {required currentLength, required isFocused, maxLength}) =>
                  null,
          textCapitalization: TextCapitalization.words,
          textInputAction: TextInputAction.done,
          style: Theme.of(context).textTheme.bodyLarge,
          decoration: InputDecoration.collapsed(
            hintText: widget.hint,
            hintStyle: Theme.of(
              context,
            ).textTheme.bodyLarge?.copyWith(color: context.glass.onGlassMuted),
          ),
          onChanged: widget.onAnswer,
        ),
      ),
    );
  }
}
