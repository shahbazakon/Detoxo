import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/core/utils/clock_format.dart';
import 'package:detoxo/features/limits/rules/domain/usecases/rule_summary.dart';
import 'package:detoxo/features/limits/unblock/domain/entities/temporary_unblock.dart';
import 'package:detoxo/features/limits/unblock/presentation/unblock_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// EVO-051 — the one place that says what is open right now.
///
/// M8 shipped grants but no inventory of them: a grant was visible only on the
/// row that minted it, and a `REEL` grant (mintable from the block screen) was
/// visible **nowhere at all**. Detoxo's promise is that you cannot forget to
/// re-enable protection; without this you could still forget *what you opened*,
/// which is the same failure wearing a different hat.
///
/// Hides itself entirely when nothing is allowed, so the ordinary dashboard is
/// unchanged. Reads the cubit's DERIVED `active` list, which is re-emitted when
/// a grant lapses — so a row leaves on its own, without a ticker.
class ActiveUnblocksCard extends StatelessWidget {
  const ActiveUnblocksCard({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<UnblockCubit, UnblockState>(
      buildWhen: (p, c) => p.active != c.active,
      builder: (context, state) {
        if (state.active.isEmpty) return const SizedBox.shrink();
        final time = localTimeFormat(context);
        return Padding(
          padding: const EdgeInsets.only(bottom: AppSpacing.md),
          child: AppCard(
            leading: const IconBadge(
              icon: Icons.lock_open,
              color: AppColors.warning,
            ),
            title: 'Allowed right now',
            subtitle: state.active.length == 1
                ? '1 thing is open'
                : '${state.active.length} things are open',
            child: Column(
              children: [
                for (final g in state.active) _Row(grant: g, time: time),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.grant, required this.time});

  final TemporaryUnblock grant;
  final String Function(int) time;

  /// The stored id is a `platformId`, a package or a host — none of them a
  /// friendly name, and resolving one would need the installed-apps scan on a
  /// path the user is waiting for. The icon carries the kind instead.
  IconData get _icon => switch (grant.targetType) {
    UnblockTargetType.reel => Icons.smart_display_outlined,
    UnblockTargetType.app => Icons.apps_outlined,
    UnblockTargetType.website => Icons.public,
  };

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.xs),
      child: Row(
        children: [
          Icon(_icon, size: 18),
          const SizedBox(width: AppSpacing.xs),
          Expanded(
            child: Text(
              grant.targetId,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: text.bodyMedium,
            ),
          ),
          Text(
            'Until ${RuleSummary.clock(grant.endMs, DateTime.now(), time: time)}',
            style: text.labelMedium,
          ),
          IconButton(
            icon: const Icon(Icons.play_arrow),
            tooltip: 'Resume blocking ${grant.targetId}',
            onPressed: () => context.read<UnblockCubit>().endEarly(
              grant.targetType,
              grant.targetId,
            ),
          ),
        ],
      ),
    );
  }
}
