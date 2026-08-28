import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/core/navigation/routes.dart';
import 'package:detoxo/core/platform/platform_capabilities.dart';
import 'package:detoxo/features/blocking/engine/presentation/service_cubit.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
import 'package:detoxo/features/permissions/domain/entities/permission_status.dart';
import 'package:detoxo/features/permissions/presentation/permission_actions.dart';
import 'package:detoxo/features/permissions/presentation/permissions_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';

/// The "Protection Status" card. Carries over every state from the old
/// `_StatusCard`: iOS/non-Android preview, protection-off with an "Enable now"
/// CTA, and the running state (now styled as the mockup's status row).
class ProtectionStatusCard extends StatelessWidget {
  const ProtectionStatusCard({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    // iOS / non-Android: blocking is Android-only — be honest, no dead CTA.
    if (PlatformCapabilities.isBlockingPreviewOnly) {
      return GlassCard(
        accent: AppColors.warning,
        child: Row(
          children: [
            const AppAnimatedIcon(
              icon: AppIcon.info,
              size: 30,
              color: AppColors.warning,
              playOnAppear: true,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Preview mode',
                    style: text.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Blocking runs on Android. iOS support is coming soon.',
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final status = context.watch<ServiceCubit>().state.status;

    // `unknown` means the status read hasn't answered (cold start, flaky
    // channel) — NOT that protection is off. A scare card that cries wolf on
    // every hiccup teaches the user to ignore the real one, so this renders
    // neutral and the next refresh (resume/stream) settles it.
    if (status == ServiceStatus.unknown) {
      return GlassCard(
        child: Row(
          children: [
            AppAnimatedIcon(
              icon: AppIcon.shieldCheck,
              size: 30,
              color: scheme.onSurfaceVariant,
              playOnAppear: true,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Protection Status',
                    style: text.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Checking…',
                    style: text.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    final running = status == ServiceStatus.running;

    if (!running) {
      // Android's restricted-settings gate can swallow the grant silently; when
      // it has, another trip to the toggle is a dead end — offer the fix instead.
      final blocked = context.watch<PermissionsCubit>().state.any(
        (s) =>
            s.kind == AppPermission.accessibility &&
            s.blockedByRestrictedSettings,
      );
      return GlassCard(
        accent: AppColors.danger,
        child: Row(
          children: [
            const AppAnimatedIcon(
              icon: AppIcon.statusOff,
              size: 30,
              color: AppColors.danger,
              playOnAppear: true,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Protection off',
                    style: text.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    blocked
                        ? 'Android is blocking the accessibility switch.'
                        : 'Enable the accessibility service to start blocking.',
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  AnimatedIconButton(
                    label: blocked ? 'Fix this' : 'Enable now',
                    icon: AppIcon.shieldCheck,
                    tint: AppColors.danger,
                    onPressed: () =>
                        requestPermission(context, AppPermission.accessibility),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }

    // Running — the mockup's "Protection Status / Active & Optimized" row.
    return GlassCard(
      accent: scheme.secondary,
      onTap: () => context.push(Routes.settings),
      child: Row(
        children: [
          _PulsingShield(color: scheme.secondary),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Protection Status',
                  style: text.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Active & Optimized',
                  style: text.bodyMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
        ],
      ),
    );
  }
}

/// Animated shield with a pulsing status dot, echoing the mockup's
/// `shield_with_heart` + ping.
class _PulsingShield extends StatelessWidget {
  const _PulsingShield({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 34,
      height: 34,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          AppAnimatedIcon(
            icon: AppIcon.shieldCheck,
            size: 32,
            color: color,
            playOnAppear: true,
          ),
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
