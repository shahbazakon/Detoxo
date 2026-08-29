import 'dart:async';

import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/core/navigation/routes.dart';
import 'package:detoxo/core/widgets/common_widgets.dart';
import 'package:detoxo/features/additional_feature/app_feedback/app_feedback.dart';
import 'package:detoxo/features/additional_feature/showcase_view/showcase_view.dart';
import 'package:detoxo/features/blocking/blocking.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

/// Named scope for the independent feedback-button coach-mark. It coexists with
/// the always-mounted dashboard tour (a separate default scope) without
/// cross-wiring — see the scoped-showcase helpers in `showcase_view`.
const String _kFeedbackTourScope = 'feedbackHelp';

/// A single, long-lived key for the feedback showcase target (mirrors
/// `FeatureShowcaseKeys` — recreating it per build would trip Flutter's
/// duplicate-GlobalKey assertion).
final GlobalKey _feedbackHelpKey = GlobalKey(
  debugLabel: 'showcase.help.feedback',
);

/// Replayable guided tours: the dashboard walkthrough (moved here from Settings)
/// and a self-contained showcase of the real feedback button in the top bar.
class FeatureTutorialScreen extends StatefulWidget {
  const FeatureTutorialScreen({super.key});

  @override
  State<FeatureTutorialScreen> createState() => _FeatureTutorialScreenState();
}

class _FeatureTutorialScreenState extends State<FeatureTutorialScreen> {
  late final ShowcaseStep _feedbackStep = ShowcaseStep(
    key: _feedbackHelpKey,
    icon: AppIcon.info,
    tone: AppTone.accent,
    title: 'Feedback button',
    body:
        'This is it — tap it any time to capture the screen, draw on it, choose '
        'Bug or Suggestion, and send it straight to our team.',
  );

  @override
  void initState() {
    super.initState();
    // Register the isolated tour controller; onSeen is a no-op because this
    // walkthrough is on-demand (nothing to persist).
    registerScopedShowcase(scope: _kFeedbackTourScope, onSeen: () {});
  }

  @override
  void dispose() {
    unregisterScopedShowcase(_kFeedbackTourScope);
    super.dispose();
  }

  /// Replays the dashboard tour. Its target keys only exist on the dashboard, so
  /// the reliable trigger is to clear the "seen" flag and return home — the
  /// dashboard restarts the tour on the flag's true→false edge once front-most.
  void _replayDashboardTour() {
    unawaited(context.read<SettingsCubit>().setShowcaseSeen(value: false));
    context.go(Routes.home);
  }

  /// Spotlights the real top-bar feedback button. Since it's hidden while
  /// `showFeedbackButton` is off, we enable it first so there's something to
  /// point at; the built-in start delay lets it lay out before the spotlight.
  Future<void> _startFeedbackTour() async {
    final settings = context.read<SettingsCubit>();
    if (!settings.state.showFeedbackButton) {
      await settings.setShowFeedbackButton(enabled: true);
    }
    if (!mounted) return;
    startScopedShowcase(scope: _kFeedbackTourScope, keys: [_feedbackHelpKey]);
  }

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      appBar: GlassAppBar(
        title: const Text('Feature tutorials'),
        // Provide our own *keyed* feedback button so the coach-mark can
        // spotlight it; suppress the auto-appended global one to avoid a
        // duplicate. It's hidden until `showFeedbackButton` is on — the tour
        // enables it first.
        globalActions: false,
        actions: [
          scopedShowcaseTarget(
            scope: _kFeedbackTourScope,
            step: _feedbackStep,
            index: 0,
            total: 1,
            child: const FeedbackActionButton(),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.md,
          0,
          AppSpacing.md,
          AppSpacing.xxl,
        ),
        children: [
          const SectionHeader('Guided tours'),
          FeatureTile(
            icon: Icons.tips_and_updates_outlined,
            animatedIcon: AppIcon.info,
            title: 'Dashboard tour',
            subtitle: "Replay the walkthrough of Detoxo's features",
            onTap: _replayDashboardTour,
          ),
          FeatureTile(
            icon: Icons.feedback_outlined,
            title: 'Feedback button',
            subtitle: 'See where it is and how to send us feedback',
            onTap: () => unawaited(_startFeedbackTour()),
          ),
          const SizedBox(height: AppSpacing.xs),
          const _Hint(
            'The feedback button lives in the top bar. Tap “Feedback button” '
            'above and we’ll point it out — it turns on automatically.',
          ),
        ],
      ),
    );
  }
}

/// A small muted hint row (leading lightbulb + wrapping text).
class _Hint extends StatelessWidget {
  const _Hint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final muted = context.glass.onGlassMuted;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.lightbulb_outline, size: 16, color: muted),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Text(
              text,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: muted),
            ),
          ),
        ],
      ),
    );
  }
}
