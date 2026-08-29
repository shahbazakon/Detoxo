import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/core/navigation/routes.dart';
import 'package:detoxo/core/utils/clock_format.dart';
import 'package:detoxo/features/limits/limits.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

/// The dashboard's entry point to rules: how many are blocking right now and
/// the next thing that will happen. Watches the app-wide [RulesCubit].
class RulesCard extends StatelessWidget {
  const RulesCard({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<RulesCubit, RulesState>(
      builder: (context, state) {
        final active = state.activeCount;
        final label = state.rules.isEmpty
            ? 'Not set up'
            : active > 0
            ? '$active active'
            : '${state.enabledCount} on';
        return AppCard(
          leading: const AppAnimatedIcon(
            icon: AppIcon.rules,
            size: 28,
            playOnAppear: true,
          ),
          title: 'Rules',
          subtitle: RuleSummary.nextEvent(
            time: localTimeFormat(context),
            state.rules,
            state.statuses,
            DateTime.now(),
          ),
          trailing: Pill(
            label: label,
            tone: active > 0 ? AppTone.success : AppTone.neutral,
          ),
          onTap: () => context.push(Routes.rules),
        );
      },
    );
  }
}
