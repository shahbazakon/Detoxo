import 'package:detoxo/features/limits/rules/domain/entities/rule.dart';

/// A starter rule the user opens in the editor, adjusts and saves.
///
/// EVO-031: the empty state used to ask for six decisions before the first
/// block existed (kind, name, days, two times, targets). A preset is one tap to
/// a pre-filled editor — never a silent save, because the first thing anyone
/// does with "Sleep" is disagree with the hours.
///
/// [template] carries no identity: the screen stamps a fresh `id` and
/// `createdAtMs` on the way to the editor, so a saved preset is an ordinary
/// rule with nothing marking where it came from.
class RulePreset {
  const RulePreset({required this.description, required this.template});

  /// One line under the preset's name, explaining what it will block.
  final String description;

  final Rule template;

  /// The template as a savable rule. `copyWith` deliberately does not expose
  /// `id` / `createdAtMs` — they are a rule's identity, not editable state — so
  /// stamping them is a constructor call.
  Rule stamp({required String id, required int createdAtMs}) => Rule(
    id: id,
    name: template.name,
    kind: template.kind,
    createdAtMs: createdAtMs,
    selection: template.selection,
    schedule: template.schedule,
    thresholdMs: template.thresholdMs,
    maxOpens: template.maxOpens,
  );

  /// Named so callers that want ONE preset (onboarding's starter rule) reach it
  /// by meaning rather than by index into [all] — reordering the empty-state
  /// list must not silently change which rule a new user gets.
  static const RulePreset workHours = RulePreset(
    description: 'Weekdays 09:00–17:00 · reels and social',
    template: Rule(
      id: '',
      name: 'Work hours',
      kind: RuleKind.schedule,
      createdAtMs: 0,
      selection: RuleSelection(categories: ['short_form_video', 'social']),
      schedule: RuleSchedule(
        days: RuleSchedule.weekdays,
        startMin: 9 * 60,
        endMin: 17 * 60,
      ),
    ),
  );

  static const RulePreset sleep = RulePreset(
    description: 'Every night 22:00–07:00 · reels, social and streaming',
    template: Rule(
      id: '',
      name: 'Sleep',
      kind: RuleKind.schedule,
      createdAtMs: 0,
      selection: RuleSelection(
        categories: ['short_form_video', 'social', 'video_streaming'],
      ),
      schedule: RuleSchedule(
        days: RuleSchedule.everyDay,
        startMin: 22 * 60,
        endMin: 7 * 60,
      ),
    ),
  );

  static const RulePreset dinner = RulePreset(
    description: 'Every day 19:00–20:00 · reels',
    template: Rule(
      id: '',
      name: 'Dinner',
      kind: RuleKind.schedule,
      createdAtMs: 0,
      selection: RuleSelection(categories: ['short_form_video']),
      schedule: RuleSchedule(
        days: RuleSchedule.everyDay,
        startMin: 19 * 60,
        endMin: 20 * 60,
      ),
    ),
  );

  static const RulePreset doomscrollBudget = RulePreset(
    description: '30 minutes of reels a day, then blocked until midnight',
    template: Rule(
      id: '',
      name: 'Doomscroll budget',
      kind: RuleKind.timeLimit,
      createdAtMs: 0,
      selection: RuleSelection(categories: ['short_form_video']),
      thresholdMs: 30 * 60000,
    ),
  );

  static const List<RulePreset> all = [
    workHours,
    sleep,
    dinner,
    doomscrollBudget,
  ];
}
