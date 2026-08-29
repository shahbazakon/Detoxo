import 'dart:async';

import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/core/di/injector.dart';
import 'package:detoxo/core/widgets/common_widgets.dart';
import 'package:detoxo/features/content_counter/content_counter_appearance/presentation/widgets/widget_preview.dart';
import 'package:detoxo/features/content_counter/content_counter_core/domain/entities/content_count.dart';
import 'package:detoxo/features/content_counter/content_counter_core/domain/entities/counter_appearance.dart';
import 'package:detoxo/features/content_counter/content_counter_core/domain/entities/counter_style_enums.dart';
import 'package:detoxo/features/content_counter/content_counter_core/presentation/content_counter_cubit.dart';
import 'package:detoxo/features/content_counter/content_counter_core/presentation/counter_appearance_cubit.dart';
import 'package:detoxo/features/content_counter/home_content_counter/domain/entities/widget_style.dart';
import 'package:detoxo/features/content_counter/home_content_counter/domain/repositories/home_widget_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Live-preview customization for the 2×2 home-screen widget: background, theme,
/// density and which lines to show. The pinned preview mirrors the real widget;
/// pinned widgets re-render as you change things. Reads the app-wide
/// `CounterAppearanceCubit` (shared with the Appearance hub) and seeds the
/// preview figures from the live `ContentCounterCubit`.
class HomeWidgetScreen extends StatelessWidget {
  const HomeWidgetScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const GlassScaffold(
      appBar: GlassAppBar(title: Text('Home widget')),
      body: SafeArea(child: _Body()),
    );
  }
}

/// Explicit control order — decoupled from enum declaration order, which the
/// wire enums were designed not to depend on.
const _themes = [WidgetTheme.system, WidgetTheme.light, WidgetTheme.dark];
const _densities = [WidgetDensity.cozy, WidgetDensity.compact];

class _Body extends StatelessWidget {
  const _Body();

  @override
  Widget build(BuildContext context) {
    // Demo figures so the preview reads well before any reels are counted.
    final count = context.select<ContentCounterCubit, ContentCount>(
      (c) => c.state,
    );
    final demo = count.total <= 0;
    final today = demo ? 137 : count.today;
    final total = demo ? 1240 : count.total;

    void setStyle(WidgetStyle style) =>
        context.read<CounterAppearanceCubit>().setWidget(style);

    return BlocBuilder<CounterAppearanceCubit, CounterAppearance>(
      builder: (context, appearance) {
        final style = appearance.widget;
        return ListView(
          padding: EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.md + MediaQuery.viewPaddingOf(context).bottom,
          ),
          children: [
            Center(
              child: WidgetPreview(style: style, today: today, total: total),
            ),
            const SizedBox(height: AppSpacing.lg),
            const SectionHeader('Background'),
            VariantCarousel(
              options: [
                for (final b in WidgetBackground.values)
                  VariantOption(
                    label: _bgLabel(b),
                    selected: style.background == b,
                    onTap: () => setStyle(style.copyWith(background: b)),
                    preview: WidgetPreview(
                      style: style.copyWith(background: b),
                      today: today,
                      total: total,
                      size: 72,
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
              onChanged: (i) => setStyle(style.copyWith(theme: _themes[i])),
              height: AppSizes.controlHeight,
            ),
            const SizedBox(height: AppSpacing.md),
            const SectionHeader('Density'),
            GlassSegmented(
              segments: const [
                (label: 'Cozy', icon: null),
                (label: 'Compact', icon: null),
              ],
              selectedIndex: _densities.indexOf(style.density),
              onChanged: (i) =>
                  setStyle(style.copyWith(density: _densities[i])),
              height: AppSizes.controlHeight,
            ),
            const SizedBox(height: AppSpacing.md),
            const SectionHeader('Show'),
            AppToggleTile(
              leading: const IconBadge(icon: Icons.today_rounded),
              title: 'Today’s count',
              value: style.showToday,
              onChanged: (v) => setStyle(style.copyWith(showToday: v)),
            ),
            const SizedBox(height: AppSpacing.sm),
            AppToggleTile(
              leading: const IconBadge(icon: Icons.label_outline_rounded),
              title: '“reels today” label',
              value: style.showLabel,
              onChanged: (v) => setStyle(style.copyWith(showLabel: v)),
            ),
            const SizedBox(height: AppSpacing.sm),
            AppToggleTile(
              leading: const IconBadge(icon: Icons.functions_rounded),
              title: 'All-time total',
              value: style.showTotal,
              onChanged: (v) => setStyle(style.copyWith(showTotal: v)),
            ),
            const SizedBox(height: AppSpacing.sm),
            AppToggleTile(
              leading: const IconBadge(icon: Icons.palette_outlined),
              title: 'Color by usage',
              subtitle: 'Tint the count green→red as you watch more',
              value: style.accentByUsage,
              onChanged: (v) => setStyle(style.copyWith(accentByUsage: v)),
            ),
            const SizedBox(height: AppSpacing.lg),
            PrimaryButton(
              label: 'Add to home screen',
              icon: Icons.add_to_home_screen_rounded,
              expand: true,
              onPressed: () => unawaited(_addWidget(context)),
            ),
          ],
        );
      },
    );
  }
}

/// Asks the launcher to pin the widget; the toast is truthful because the
/// native `pinContentWidget` answers false on launchers that can't pin.
Future<void> _addWidget(BuildContext context) async {
  final widget = sl<HomeWidgetRepository>();
  final ok = await widget.pin();
  await widget.refresh();
  if (!context.mounted) return;
  GlassToast.show(
    context,
    ok
        ? 'Confirm the prompt to add the widget to your home screen.'
        : 'Your launcher doesn’t support adding widgets this way — '
              'long-press your home screen and pick Detoxo from Widgets.',
    tone: ok ? AppTone.neutral : AppTone.warning,
  );
}

String _bgLabel(WidgetBackground b) => switch (b) {
  WidgetBackground.glassDark => 'Glass',
  WidgetBackground.glassBrand => 'Brand',
  WidgetBackground.solid => 'Solid',
  WidgetBackground.usageTint => 'Usage',
};
