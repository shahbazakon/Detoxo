import 'dart:async';

import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/core/di/injector.dart';
import 'package:detoxo/core/widgets/common_widgets.dart';
import 'package:detoxo/features/content_counter/content_counter_appearance/presentation/widgets/variant_carousel.dart';
import 'package:detoxo/features/content_counter/content_counter_appearance/presentation/widgets/widget_preview.dart';
import 'package:detoxo/features/content_counter/content_counter_core/domain/entities/counter_appearance.dart';
import 'package:detoxo/features/content_counter/content_counter_core/domain/entities/counter_style_enums.dart';
import 'package:detoxo/features/content_counter/content_counter_core/domain/repositories/content_counter_repository.dart';
import 'package:detoxo/features/content_counter/content_counter_core/domain/repositories/counter_appearance_repository.dart';
import 'package:detoxo/features/content_counter/content_counter_core/presentation/counter_appearance_cubit.dart';
import 'package:detoxo/features/content_counter/home_content_counter/domain/entities/widget_style.dart';
import 'package:detoxo/features/content_counter/home_content_counter/domain/repositories/home_widget_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Live-preview customization for the 2×2 home-screen widget: background, theme,
/// density and which lines to show. The pinned preview mirrors the real widget;
/// pinned widgets re-render as you change things.
class HomeWidgetScreen extends StatelessWidget {
  const HomeWidgetScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocProvider(
      create: (_) => CounterAppearanceCubit(sl<CounterAppearanceRepository>()),
      child: const GlassScaffold(
        appBar: GlassAppBar(title: Text('Home widget')),
        body: SafeArea(child: _Body()),
      ),
    );
  }
}

class _Body extends StatefulWidget {
  const _Body();

  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  final HomeWidgetRepository _widget = sl<HomeWidgetRepository>();

  // Demo figures so the preview reads well before any reels are counted.
  int _today = 137;
  int _total = 1240;

  @override
  void initState() {
    super.initState();
    unawaited(_loadCounts());
  }

  Future<void> _loadCounts() async {
    final count = await sl<ContentCounterRepository>().current();
    if (!mounted || count.total <= 0) return;
    setState(() {
      _today = count.today;
      _total = count.total;
    });
  }

  void _setStyle(WidgetStyle style) =>
      context.read<CounterAppearanceCubit>().setWidget(style);

  Future<void> _addWidget() async {
    final ok = await _widget.pin();
    await _widget.refresh();
    if (!mounted) return;
    GlassToast.show(
      context,
      ok
          ? 'Confirm the prompt to add the widget to your home screen.'
          : 'Your launcher doesn’t support adding widgets this way — '
                'long-press your home screen and pick Detoxo from Widgets.',
      tone: ok ? AppTone.neutral : AppTone.warning,
    );
  }

  @override
  Widget build(BuildContext context) {
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
              child: WidgetPreview(style: style, today: _today, total: _total),
            ),
            const SizedBox(height: AppSpacing.lg),
            const SectionHeader('Background'),
            VariantCarousel(
              options: [
                for (final b in WidgetBackground.values)
                  VariantOption(
                    label: _bgLabel(b),
                    selected: style.background == b,
                    onTap: () => _setStyle(style.copyWith(background: b)),
                    preview: WidgetPreview(
                      style: style.copyWith(background: b),
                      today: _today,
                      total: _total,
                      size: 72,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            const SectionHeader('Theme'),
            AdaptiveSegmentedControl(
              labels: const ['System', 'Light', 'Dark'],
              selectedIndex: style.theme.index,
              onChanged: (i) =>
                  _setStyle(style.copyWith(theme: WidgetTheme.values[i])),
            ),
            const SizedBox(height: AppSpacing.md),
            const SectionHeader('Density'),
            AdaptiveSegmentedControl(
              labels: const ['Cozy', 'Compact'],
              selectedIndex: style.density.index,
              onChanged: (i) =>
                  _setStyle(style.copyWith(density: WidgetDensity.values[i])),
            ),
            const SizedBox(height: AppSpacing.md),
            const SectionHeader('Show'),
            AppToggleTile(
              leading: const IconBadge(icon: Icons.today_rounded),
              title: 'Today’s count',
              value: style.showToday,
              onChanged: (v) => _setStyle(style.copyWith(showToday: v)),
            ),
            const SizedBox(height: AppSpacing.sm),
            AppToggleTile(
              leading: const IconBadge(icon: Icons.label_outline_rounded),
              title: '“reels today” label',
              value: style.showLabel,
              onChanged: (v) => _setStyle(style.copyWith(showLabel: v)),
            ),
            const SizedBox(height: AppSpacing.sm),
            AppToggleTile(
              leading: const IconBadge(icon: Icons.functions_rounded),
              title: 'All-time total',
              value: style.showTotal,
              onChanged: (v) => _setStyle(style.copyWith(showTotal: v)),
            ),
            const SizedBox(height: AppSpacing.sm),
            AppToggleTile(
              leading: const IconBadge(icon: Icons.palette_outlined),
              title: 'Color by usage',
              subtitle: 'Tint the count green→red as you watch more',
              value: style.accentByUsage,
              onChanged: (v) => _setStyle(style.copyWith(accentByUsage: v)),
            ),
            const SizedBox(height: AppSpacing.lg),
            PrimaryButton(
              label: 'Add to home screen',
              icon: Icons.add_to_home_screen_rounded,
              expand: true,
              onPressed: () => unawaited(_addWidget()),
            ),
          ],
        );
      },
    );
  }
}

String _bgLabel(WidgetBackground b) => switch (b) {
  WidgetBackground.glassDark => 'Glass',
  WidgetBackground.glassBrand => 'Brand',
  WidgetBackground.solid => 'Solid',
  WidgetBackground.usageTint => 'Usage',
};
