import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/features/additional_feature/app_feedback/app_feedback.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/app_settings.dart';
import 'package:detoxo/features/blocking/shared/presentation/settings_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// The "Report an issue" entry point. A glass dialog that explains the bug-report
/// flow, lets the user enable the always-visible top-bar feedback button, and
/// can launch the annotated-screenshot report overlay immediately.
///
/// "Report a bug now" pops the dialog first, then calls
/// [FeedbackLauncher.show] with the caller's (screen) context so the
/// `BetterFeedback` overlay captures the underlying screen — not the dialog.
abstract final class ReportIssueDialog {
  static Future<void> show(BuildContext context) {
    return AppDialog.show<void>(
      context: context,
      title: 'Report an issue',
      icon: Icons.bug_report_outlined,
      message:
          'Found a bug? Tap "Report a bug now" to capture the current screen, '
          'draw on it, choose Bug or Suggestion, and send it straight to our '
          'team with your device details attached.\n\n'
          'Want to report from wherever a bug happens? Turn on the feedback '
          'button below and it appears in every top bar.',
      content: const _FeedbackButtonToggle(),
      actions: [
        GhostButton(
          label: 'Close',
          onPressed: () => Navigator.of(context).pop(),
        ),
        PrimaryButton(
          label: 'Report a bug',
          icon: Icons.bug_report_outlined,
          onPressed: () {
            Navigator.of(context).pop();
            FeedbackLauncher.show(context);
          },
        ),
      ],
    );
  }
}

/// The live toggle bound to `settings.showFeedbackButton`. Wrapped in a
/// [BlocBuilder] so it reflects the flag immediately as it's flipped.
class _FeedbackButtonToggle extends StatelessWidget {
  const _FeedbackButtonToggle();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<SettingsCubit, AppSettings>(
      builder: (context, settings) {
        return AppToggleTile(
          leading: Icon(
            Icons.feedback_outlined,
            color: Theme.of(context).colorScheme.secondary,
          ),
          title: 'Feedback button',
          subtitle: 'Show a feedback button in every top bar',
          value: settings.showFeedbackButton,
          onChanged: (v) =>
              context.read<SettingsCubit>().setShowFeedbackButton(enabled: v),
        );
      },
    );
  }
}
