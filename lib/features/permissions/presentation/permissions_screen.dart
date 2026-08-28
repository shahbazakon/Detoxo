import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/core/navigation/routes.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
import 'package:detoxo/features/permissions/domain/entities/permission_status.dart';
import 'package:detoxo/features/permissions/presentation/permission_actions.dart';
import 'package:detoxo/features/permissions/presentation/permissions_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

/// Guided permission funnel. Re-checks statuses whenever the app resumes (the
/// user typically grants from a system settings screen and returns).
class PermissionsScreen extends StatefulWidget {
  const PermissionsScreen({super.key});

  @override
  State<PermissionsScreen> createState() => _PermissionsScreenState();
}

class _PermissionsScreenState extends State<PermissionsScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    context.read<PermissionsCubit>().refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      context.read<PermissionsCubit>().refresh();
    }
  }

  IconData _iconFor(AppPermission p) => switch (p) {
    AppPermission.accessibility => Icons.accessibility_new,
    AppPermission.overlay => Icons.layers,
    AppPermission.notifications => Icons.notifications,
    AppPermission.usageAccess => Icons.bar_chart,
    AppPermission.batteryOptimization => Icons.battery_charging_full,
    AppPermission.deviceAdmin => Icons.shield,
  };

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      appBar: const GlassAppBar(title: Text('Set up protection')),
      body: BlocBuilder<PermissionsCubit, List<PermissionStatus>>(
        builder: (context, statuses) {
          final cubit = context.read<PermissionsCubit>();
          final allRequired = cubit.allRequiredGranted;
          final required = statuses.where((s) => s.kind.required).toList();
          final optional = statuses.where((s) => !s.kind.required).toList();
          // Same predicate as the gate — the "N of M" row, the cards and the
          // Continue button must never contradict each other under a flaky
          // (unknown) read.
          final grantedReq = required.where(cubit.effectivelyGranted).length;
          final progress = required.isEmpty
              ? 1.0
              : grantedReq / required.length;

          return Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.md,
                    AppSpacing.md,
                    AppSpacing.md,
                    AppSpacing.md,
                  ),
                  children: [
                    Text(
                      'Grant a few permissions so Detoxo can do its job.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    Row(
                      children: [
                        Expanded(child: ProgressBar(progress: progress)),
                        const SizedBox(width: AppSpacing.sm),
                        Text(
                          '$grantedReq of ${required.length}',
                          style: Theme.of(context).textTheme.labelMedium,
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.md),
                    if (required.isNotEmpty) ...[
                      const _SectionLabel('Required to block'),
                      EntranceList(
                        children: [for (final s in required) _card(context, s)],
                      ),
                      const SizedBox(height: AppSpacing.md),
                    ],
                    if (optional.isNotEmpty) ...[
                      const _SectionLabel('Recommended'),
                      EntranceList(
                        children: [for (final s in optional) _card(context, s)],
                      ),
                    ],
                  ],
                ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  child: PrimaryButton(
                    label: allRequired
                        ? 'Continue'
                        : 'Grant required permissions',
                    expand: true,
                    onPressed: allRequired
                        ? () => context.go(Routes.home)
                        : null,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _card(BuildContext context, PermissionStatus status) {
    final cubit = context.read<PermissionsCubit>();
    final effective = cubit.effectivelyGranted(status);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: PermissionCard(
        icon: _iconFor(status.kind),
        title: status.kind.label,
        why: status.kind.why,
        granted: effective,
        // Genuinely unknown (no granted history): neutral "Checking…", not a
        // red denied row.
        unknown: status.state == PermissionState.unknown,
        isRequired: status.kind.required,
        permanentlyDenied: status.permanentlyDenied,
        actionLabel: status.blockedByRestrictedSettings ? 'Fix this' : null,
        onGrant: () => requestPermission(context, status.kind),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: AppSpacing.sm),
      child: Text(
        label.toUpperCase(),
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}
