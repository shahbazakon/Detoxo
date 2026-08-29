import 'package:detoxo/features/additional_feature/app_feedback/presentation/feedback_launcher.dart';
import 'package:detoxo/features/blocking/blocking.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// The global feedback button injected into every app bar (via
/// `GlassAppBar.globalActionsBuilder`). It watches the settings toggle and
/// collapses to nothing when the user has hidden it.
class FeedbackActionButton extends StatelessWidget {
  const FeedbackActionButton({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocSelector<SettingsCubit, AppSettings, bool>(
      selector: (settings) => settings.showFeedbackButton,
      builder: (context, show) {
        if (!show) return const SizedBox.shrink();
        return IconButton(
          tooltip: 'Send feedback',
          icon: const Icon(Icons.feedback_outlined),
          onPressed: () => FeedbackLauncher.show(context),
        );
      },
    );
  }
}
