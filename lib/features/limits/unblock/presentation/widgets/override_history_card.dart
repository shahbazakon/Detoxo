import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/features/limits/unblock/domain/usecases/unblock_quota.dart';
import 'package:detoxo/features/limits/unblock/presentation/unblock_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// EVO-052 — the ledger, said back.
///
/// M8 asks the user to *name a reason* before it lifts a locked rule; that
/// friction is the whole mechanism. The reason was then written to disk and
/// shown to nobody, including them — a diary nobody keeps.
///
/// Deliberately a plain sentence, not a chart or a streak: a count of lapses
/// rendered as a score is the shame-chart pattern the product overview
/// explicitly rejects. The reasons are the user's own words about their own
/// week, which is a different thing.
///
/// Hidden entirely when the count is 0, so nothing appears until there is
/// something true to say.
class OverrideHistoryCard extends StatelessWidget {
  const OverrideHistoryCard({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<UnblockCubit, UnblockState>(
      buildWhen: (p, c) => p.ledger != c.ledger || p.config != c.config,
      builder: (context, state) {
        final summary = UnblockQuota.overrideSummary(
          state.ledger,
          state.config,
          DateTime.now().millisecondsSinceEpoch,
        );
        if (summary.count == 0) return const SizedBox.shrink();
        // Distinct reasons in the order they were given, so "both Schedule
        // change" reads as one line rather than the same words twice.
        final reasons = <String>[];
        for (final r in summary.reasons) {
          if (!reasons.contains(r.label)) reasons.add(r.label);
        }
        final left = state.overridesLeft;
        return Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.lg),
          child: AppCard(
            leading: const IconBadge(
              icon: Icons.lock_open,
              color: AppColors.warning,
            ),
            title: summary.count == 1
                ? '1 override this period'
                : '${summary.count} overrides this period',
            subtitle: reasons.isEmpty
                ? '$left left'
                : '${reasons.join(' · ')} — $left left',
          ),
        );
      },
    );
  }
}
