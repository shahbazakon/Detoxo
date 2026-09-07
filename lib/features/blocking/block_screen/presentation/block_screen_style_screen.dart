import 'dart:async';

import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/features/blocking/block_screen/domain/entities/block_screen_payload.dart';
import 'package:detoxo/features/blocking/block_screen/domain/entities/block_screen_style.dart';
import 'package:detoxo/features/blocking/block_screen/presentation/block_screen_style_cubit.dart';
import 'package:detoxo/features/blocking/block_screen/presentation/widgets/block_screen_preview.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
import 'package:detoxo/features/blocking/shared/presentation/settings_cubit.dart';
import 'package:detoxo/features/content_counter/content_counter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Live-preview customisation for the block screen: background, theme, which
/// lines to show and the back-button countdown, plus "Try it on your phone",
/// which raises the real wall over this screen. Reads the app-wide
/// `BlockScreenStyleCubit` (shared with the Appearance hub); the preview
/// reflects the user's current plan.
class BlockScreenStyleScreen extends StatelessWidget {
  const BlockScreenStyleScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const GlassScaffold(
      appBar: GlassAppBar(title: Text('Block screen')),
      body: SafeArea(child: _Body()),
    );
  }
}

/// Explicit control order — decoupled from enum declaration order.
const _themes = [WidgetTheme.system, WidgetTheme.light, WidgetTheme.dark];

class _Body extends StatelessWidget {
  const _Body();

  @override
  Widget build(BuildContext context) {
    // Only the fields the preview reads: the editor must not rebuild on every
    // counter tick or unrelated settings commit.
    final (today, overlayGranted) = context
        .select<ContentCounterCubit, (int, bool?)>(
          (c) => (c.state.today, c.state.overlayGranted),
        );
    final (plan, allowance) = context
        .select<SettingsCubit, (BlockingPlan, int)>(
          (c) => (c.state.activePlan, c.state.reelAllowance),
        );
    final payload = BlockScreenPayload.preview(
      plan: plan,
      allowance: allowance,
      todayCount: today,
    );
    final cubit = context.read<BlockScreenStyleCubit>();

    return BlocBuilder<BlockScreenStyleCubit, BlockScreenStyle>(
      builder: (context, style) {
        return ListView(
          padding: EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.md + MediaQuery.viewPaddingOf(context).bottom,
          ),
          children: [
            _PreviewStage(style: style, payload: payload),
            const SizedBox(height: AppSpacing.sm),
            SecondaryButton(
              label: 'Try it on your phone',
              icon: Icons.fullscreen_rounded,
              expand: true,
              onPressed: () => unawaited(
                _tryIt(context, payload, overlayGranted: overlayGranted),
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            const SectionHeader('Background'),
            VariantCarousel(
              height: 132,
              cardWidth: 104,
              options: [
                for (final b in WidgetBackground.values)
                  VariantOption(
                    label: _bgLabel(b),
                    selected: style.background == b,
                    onTap: () => cubit.setBackground(b),
                    preview: BlockScreenPreview(
                      style: style.copyWith(background: b),
                      payload: payload,
                      height: 88,
                      compact: true,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            const SectionHeader('Theme'),
            GlassSegmented(
              segments: const [
                (label: 'System', icon: null),
                (label: 'Light', icon: null),
                (label: 'Dark', icon: null),
              ],
              selectedIndex: _themes.indexOf(style.theme),
              onChanged: (i) => cubit.setTheme(_themes[i]),
              height: AppSizes.controlHeight,
            ),
            const SizedBox(height: AppSpacing.md),
            const SectionHeader('Show'),
            AppToggleTile(
              leading: const IconBadge(icon: Icons.movie_filter_rounded),
              title: 'Today’s reel count',
              subtitle: 'How many reels you’ve watched today',
              value: style.showCount,
              onChanged: (v) => cubit.setShowCount(show: v),
            ),
            const SizedBox(height: AppSpacing.sm),
            AppToggleTile(
              leading: const IconBadge(icon: Icons.repeat_rounded),
              title: 'Times opened today',
              subtitle:
                  'How often you’ve opened the app today (needs Usage access)',
              value: style.showOpens,
              onChanged: (v) => cubit.setShowOpens(show: v),
            ),
            const SizedBox(height: AppSpacing.sm),
            AppToggleTile(
              leading: const IconBadge(icon: Icons.palette_outlined),
              title: 'Color by usage',
              subtitle: 'Tint the accent green→red as you watch more',
              value: style.accentByUsage,
              onChanged: (v) => cubit.setAccentByUsage(on: v),
            ),
            const SizedBox(height: AppSpacing.md),
            const SectionHeader('Friction'),
            AppToggleTile(
              leading: const IconBadge(icon: Icons.hourglass_bottom_rounded),
              title: 'Wait before going back',
              subtitle: 'The way back into the app unlocks after 5 seconds',
              value: style.backDelaySec > 0,
              onChanged: (v) => cubit.setBackDelay(on: v),
            ),
          ],
        );
      },
    );
  }
}

/// Raises the real wall. The overlay grant is read from the tri-state the app
/// already holds (`ContentCount.overlayGranted`): a definite `false` gets the
/// permission hint; anything else that fails gets a neutral message, because
/// `showBlockScreen`'s false cannot tell "off" from "no native side".
Future<void> _tryIt(
  BuildContext context,
  BlockScreenPayload payload, {
  required bool? overlayGranted,
}) async {
  if (overlayGranted == false) {
    GlassToast.show(
      context,
      'Needs “Display over other apps” — allow it from Appearance.',
      tone: AppTone.warning,
    );
    return;
  }
  final shown = await context.read<BlockScreenStyleCubit>().preview(payload);
  if (!context.mounted || shown) return;
  GlassToast.show(
    context,
    'Couldn’t show the preview. Is the block screen switched on?',
  );
}

class _PreviewStage extends StatelessWidget {
  const _PreviewStage({required this.style, required this.payload});

  final BlockScreenStyle style;
  final BlockScreenPayload payload;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [context.glass.fillTop, context.glass.fillBottom],
        ),
        border: Border.all(color: context.glass.border),
      ),
      child: Center(
        child: BlockScreenPreview(style: style, payload: payload, height: 320),
      ),
    );
  }
}

String _bgLabel(WidgetBackground b) => switch (b) {
  WidgetBackground.glassDark => 'Glass',
  WidgetBackground.glassBrand => 'Brand',
  WidgetBackground.solid => 'Solid',
  WidgetBackground.usageTint => 'Usage',
};
