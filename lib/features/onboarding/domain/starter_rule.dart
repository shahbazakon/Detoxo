import 'package:detoxo/features/limits/limits.dart';
import 'package:detoxo/features/onboarding/domain/entities/onboarding_progress.dart';

/// The preset the survey's answer maps to.
///
/// | `mattersMost`                     | Rule                                        |
/// |-----------------------------------|---------------------------------------------|
/// | `SLEEP`                           | Schedule, daily 22:00–07:00 (overnight wrap) |
/// | `FOCUS`                           | Schedule, Mon–Fri 09:00–17:00                |
/// | `PRESENT`/`MENTAL`/`OTHER`/skipped | Time limit, 30 min/day, `END_OF_DAY`         |
///
/// **Null is a real answer, not a missing one.** Skipping the survey used to
/// leave `mattersMost` null, which the commitment screen rendered as the
/// 30-minute budget while the sync refused to write anything — the app stating
/// a behaviour it did not implement, on the last screen before the grant. Null
/// now maps to the same preset that copy describes, so the promise is kept.
///
/// Exposed separately from [starterRule] so the commitment screen can render
/// the promise FROM the preset instead of restating its hours in prose — the
/// third copy of "22:00–07:00" that this file exists to avoid.
RulePreset starterPreset(MattersMost? mattersMost) => switch (mattersMost) {
  MattersMost.sleep => RulePreset.sleep,
  MattersMost.focus => RulePreset.workHours,
  MattersMost.present ||
  MattersMost.mental ||
  MattersMost.other ||
  null => RulePreset.doomscrollBudget,
};

/// The one rule onboarding writes, mapped from the survey so the mapping stays
/// legible and testable.
///
/// Built from [RulePreset], not from scratch: M3 already ships these three
/// windows, and a second copy of "22:00–07:00" is a second thing to keep right.
/// The preset's category selection is replaced by the feeds the user actually
/// picked — a starter rule must block what they chose, not a default taxonomy.
///
/// `lockPeriod: END_OF_DAY` needs no field: `Rule.toJson` already emits it as
/// the only time-limit lock behaviour M3 shipped.
Rule starterRule({
  required MattersMost? mattersMost,
  required Set<String> platforms,
  required String id,
  required int nowMs,
}) => starterPreset(mattersMost)
    .stamp(id: id, createdAtMs: nowMs)
    .copyWith(selection: RuleSelection(platforms: platforms.toList()..sort()));
