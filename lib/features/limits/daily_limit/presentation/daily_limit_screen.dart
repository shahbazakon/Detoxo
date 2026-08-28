import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/core/widgets/common_widgets.dart';
import 'package:detoxo/features/additional_feature/app_feedback/app_feedback.dart';
import 'package:detoxo/features/limits/daily_limit/domain/entities/daily_limit.dart';
import 'package:detoxo/features/limits/daily_limit/presentation/daily_limit_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Reads and mutates the app-wide [DailyLimitCubit] (provided in `main.dart`),
/// not a private instance — so a saved limit updates the dashboard ring live.
class DailyLimitScreen extends StatelessWidget {
  const DailyLimitScreen({super.key});

  @override
  Widget build(BuildContext context) => const _DailyLimitView();
}

class _DailyLimitView extends StatefulWidget {
  const _DailyLimitView();

  @override
  State<_DailyLimitView> createState() => _DailyLimitViewState();
}

class _DailyLimitViewState extends State<_DailyLimitView> {
  double? _draftMinutes;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Daily limit'),
        actions: const [FeedbackActionButton()],
      ),
      body: SafeArea(
        child: BlocBuilder<DailyLimitCubit, DailyLimit>(
          builder: (context, limit) {
            final minutes = _draftMinutes ?? limit.limit.inMinutes.toDouble();
            final consumed = limit.consumed.inMinutes;
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                SectionCard(
                  title: 'Today',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        limit.limit == Duration.zero
                            ? 'No daily limit set'
                            : '$consumed of ${limit.limit.inMinutes} min used',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 12),
                      LinearProgressIndicator(
                        value: limit.limit == Duration.zero
                            ? 0
                            : (consumed / limit.limit.inMinutes).clamp(
                                0.0,
                                1.0,
                              ),
                        minHeight: 10,
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                SectionCard(
                  title: 'Set your daily limit',
                  child: Column(
                    children: [
                      Text(
                        '${minutes.round()} minutes per day',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      Slider(
                        value: minutes.clamp(0, 180),
                        max: 180,
                        divisions: 36,
                        label: '${minutes.round()} min',
                        onChanged: (v) => setState(() => _draftMinutes = v),
                      ),
                      const SizedBox(height: 8),
                      AnimatedIconButton(
                        label: 'Save limit',
                        icon: AppIcon.check,
                        expand: true,
                        onPressed: () {
                          context.read<DailyLimitCubit>().setLimit(
                            Duration(minutes: minutes.round()),
                          );
                          setState(() => _draftMinutes = null);
                          GlassToast.show(
                            context,
                            'Daily limit saved.',
                            tone: AppTone.success,
                          );
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                const InfoBanner(
                  text:
                      'Usage counting is enforced by the native service on a real '
                      'device with usage access granted.',
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class InfoBanner extends StatelessWidget {
  const InfoBanner({
    required this.text,
    this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    super.key,
  });
  final String text;
  final String? title;
  final String? subtitle;

  /// Optional compact action shown at the trailing edge (e.g. an "Update"
  /// button on the app-version banner).
  final Widget? trailing;

  /// Makes the whole banner tappable (e.g. to trigger a manual update check).
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final banner = Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          const AppAnimatedIcon(
            icon: AppIcon.info,
            size: 20,
            interactive: true,
            playOnAppear: true,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (title != null)
                  Text(title!, style: Theme.of(context).textTheme.titleSmall),
                if (title != null) const SizedBox(height: 4),
                Text(text, style: Theme.of(context).textTheme.bodySmall),
                if (subtitle != null) const SizedBox(height: 4),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 10), trailing!],
        ],
      ),
    );
    if (onTap == null) return banner;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: banner,
    );
  }
}
