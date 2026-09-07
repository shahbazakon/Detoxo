import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/core/navigation/routes.dart';
import 'package:detoxo/core/utils/clock_format.dart';
import 'package:detoxo/features/limits/limits.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

/// The dashboard's entry point to rules: how many are blocking right now and
/// the next thing that will happen. Watches the app-wide [RulesCubit].
///
/// Styled as the status row that used to be the Protection Status card: a
/// tinted [GlassCard] with a leading glyph (pulsing dot while a rule is live),
/// title / next-event subtitle, a status [Pill] and a chevron.
class RulesCard extends StatelessWidget {
  const RulesCard({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return BlocBuilder<RulesCubit, RulesState>(
      builder: (context, state) {
        final active = state.activeCount;
        final live = active > 0;
        final label = state.rules.isEmpty
            ? 'Not set up'
            : live
            ? '$active active'
            : '${state.enabledCount} on';
        final tone = live ? AppTone.success : AppTone.neutral;
        // Live → success tint; set up but idle → the house accent; nothing
        // set up → plain glass, so the card doesn't shout about an empty list.
        final accent = live
            ? AppColors.success
            : state.rules.isEmpty
            ? null
            : scheme.secondary;
        final iconColor = accent ?? scheme.onSurfaceVariant;

        return GlassCard(
          accent: accent,
          onTap: () => context.push(Routes.rules),
          child: Row(
            children: [
              _PulsingIcon(color: iconColor, pulsing: live),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Rules',
                      style: text.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      RuleSummary.nextEvent(
                        time: localTimeFormat(context),
                        state.rules,
                        state.statuses,
                        DateTime.now(),
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Pill(label: label, tone: tone),
              const SizedBox(width: AppSpacing.xs),
              Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
            ],
          ),
        );
      },
    );
  }
}

/// Animated rules glyph with a status dot in its corner; the dot only shows
/// (and pulses) while a rule is blocking right now.
class _PulsingIcon extends StatelessWidget {
  const _PulsingIcon({required this.color, required this.pulsing});

  final Color color;
  final bool pulsing;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 34,
      height: 34,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          AppAnimatedIcon(
            icon: AppIcon.rules,
            size: 32,
            color: color,
            playOnAppear: true,
          ),
          if (pulsing)
            Positioned(
              top: -2,
              right: -2,
              child: StatusDot(color: color, size: 8),
            ),
        ],
      ),
    );
  }
}
