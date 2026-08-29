import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/core/navigation/routes.dart';
import 'package:detoxo/core/widgets/common_widgets.dart';
import 'package:detoxo/features/blocking/blocking.dart';
import 'package:detoxo/features/content_counter/content_counter.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

/// One home for how Detoxo *looks*: the app theme (a Light / Dark segmented
/// control that auto-follows the device by default) and background, the reel
/// counter's two surfaces — the floating bubble and the home-screen widget —
/// and the block screen, each shown as a large live preview you tap to
/// customise. The bubble and the block screen carry their own on/off; the
/// widget and the counter editors are gated by the counting master.
class AppearanceScreen extends StatelessWidget {
  const AppearanceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return GlassScaffold(
      appBar: const GlassAppBar(title: Text('Appearance')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          AppSpacing.md,
          0,
          AppSpacing.md,
          AppSpacing.xxl + MediaQuery.viewPaddingOf(context).bottom,
        ),
        children: const [
          // ── App theme ───────────────────────────────────────────────────
          SectionHeader('Theme'),
          _ThemeControl(),

          // ── App background ──────────────────────────────────────────────
          SectionHeader('Background'),
          _BackgroundSection(),

          // ── Reel counter: master switch + the two surfaces as cards ─────
          SectionHeader('Reel counter'),
          _CounterSection(),

          // ── Block screen: the wall raised at the moment of a block ──────
          SizedBox(height: AppSpacing.md),
          SectionHeader('Block screen'),
          _BlockScreenSection(),
        ],
      ),
    );
  }
}

// ── Block screen section ────────────────────────────────────────────────────────

/// The wall as one full-width card: a live landscape preview you tap to edit,
/// its own on/off switch, and the truthful overlay-permission notice (the same
/// tri-state read the bubble card uses — a wall can only appear with the grant).
class _BlockScreenSection extends StatelessWidget {
  const _BlockScreenSection();

  @override
  Widget build(BuildContext context) {
    final style = context.watch<BlockScreenStyleCubit>().state;
    // Only the fields the card reads — not every counter tick / settings commit.
    final (today, overlayGranted) = context
        .select<ContentCounterCubit, (int, bool?)>(
          (c) => (c.state.today, c.state.overlayGranted),
        );
    final (plan, allowance) = context
        .select<SettingsCubit, (BlockingPlan, int)>(
          (c) => (c.state.activePlan, c.state.reelAllowance),
        );
    final cubit = context.read<BlockScreenStyleCubit>();
    return _SurfaceCard(
      title: 'Block screen',
      previewHeight: 150,
      preview: BlockScreenPreview(
        style: style,
        payload: BlockScreenPayload.preview(
          plan: plan,
          allowance: allowance,
          todayCount: today,
        ),
        height: 150,
        compact: true,
      ),
      editable: style.enabled,
      onEdit: () => unawaited(context.push(Routes.blockScreenStyle)),
      trailing: AppToggle(
        value: style.enabled,
        semanticLabel: 'Block screen',
        onChanged: (on) => cubit.setEnabled(enabled: on),
      ),
      disabledHint: 'Block screen off — blocks fall back to a short toast',
      notice: style.enabled && overlayGranted == false
          ? 'Needs “Display over other apps” — tap to allow'
          : null,
      onNotice: () =>
          unawaited(context.read<ContentCounterCubit>().requestOverlay()),
    );
  }
}

// ── Reel counter section ────────────────────────────────────────────────────────

/// Master switch + the two surfaces. Reads the app-wide cubits: the live count
/// (switch states, overlay grant, representative figures) and the appearance
/// (live styles — an edit made in either editor shows here on return without a
/// re-pull). No local mirrors of native state.
class _CounterSection extends StatelessWidget {
  const _CounterSection();

  @override
  Widget build(BuildContext context) {
    final count = context.watch<ContentCounterCubit>().state;
    final appearance = context.watch<CounterAppearanceCubit>().state;
    final cubit = context.read<ContentCounterCubit>();
    // Representative figures so the previews read at a legible number even
    // before anything is counted today.
    final today = count.today > 0 ? count.today : 137;
    final total = count.total > 0 ? count.total : 1240;
    final counterOn = count.enabled;
    final bubbleOn = count.bubbleEnabled;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppToggleTile(
          leading: const IconBadge(icon: Icons.movie_filter_rounded),
          title: 'Count short videos',
          value: counterOn,
          onChanged: (on) => unawaited(cubit.setEnabled(enabled: on)),
        ),
        const SizedBox(height: AppSpacing.sm),
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _SurfaceCard(
                  title: 'Bubble',
                  preview: BubblePreview(
                    style: appearance.bubble,
                    count: today,
                    area: 88,
                  ),
                  editable: counterOn && bubbleOn,
                  onEdit: () => unawaited(context.push(Routes.bubbleStyle)),
                  trailing: AppToggle(
                    value: bubbleOn,
                    enabled: counterOn,
                    onChanged: (on) =>
                        unawaited(cubit.setBubbleEnabled(enabled: on)),
                  ),
                  disabledHint: !counterOn ? 'Counting off' : 'Bubble off',
                  // Truthful state: the switch is on but the overlay grant is
                  // missing, so no bubble can appear — say so, offer the fix.
                  notice: count.bubbleBlocked
                      ? 'Needs “Display over other apps” — tap to allow'
                      : null,
                  onNotice: () => unawaited(cubit.requestOverlay()),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: _SurfaceCard(
                  title: 'Widget',
                  preview: WidgetPreview(
                    style: appearance.widget,
                    today: today,
                    total: total,
                    size: 88,
                  ),
                  editable: counterOn,
                  onEdit: () => unawaited(context.push(Routes.homeWidget)),
                  disabledHint: 'Counting off',
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ── Theme control (segmented + match-system, no glass card) ─────────────────────

/// The app-theme control, kept deliberately flat (no card): a custom sliding
/// **Light / Dark** segmented button plus a compact **Match system** row that
/// keeps the app auto-following the device (the default). Picking a segment
/// commits an explicit theme and turns matching off; while matching is on the
/// segment dims to show it's device-driven, not locked. The whole app re-themes
/// instantly.
class _ThemeControl extends StatelessWidget {
  const _ThemeControl();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<SettingsCubit, AppSettings>(
      buildWhen: (a, b) => a.themeMode != b.themeMode,
      builder: (context, settings) {
        final mode = settings.themeMode;
        final system = mode == AppThemeMode.system;
        final dark = Theme.of(context).brightness == Brightness.dark;
        final selectedIndex = switch (mode) {
          AppThemeMode.light => 0,
          AppThemeMode.dark => 1,
          AppThemeMode.system => dark ? 1 : 0,
        };
        final cubit = context.read<SettingsCubit>();
        final text = Theme.of(context).textTheme;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AnimatedOpacity(
              duration: AppDurations.fast,
              opacity: system ? 0.55 : 1,
              child: GlassSegmented(
                segments: const [
                  (label: 'Light', icon: Icons.light_mode_rounded),
                  (label: 'Dark', icon: Icons.dark_mode_rounded),
                ],
                selectedIndex: selectedIndex,
                onChanged: (i) => cubit.setThemeMode(
                  i == 0 ? AppThemeMode.light : AppThemeMode.dark,
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Icon(
                  Icons.brightness_auto_rounded,
                  size: 20,
                  color: context.glass.onGlassMuted,
                ),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    'Match system',
                    style: text.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                AppToggle(
                  value: system,
                  onChanged: (on) => cubit.setThemeMode(
                    on
                        ? AppThemeMode.system
                        : dark
                        ? AppThemeMode.dark
                        : AppThemeMode.light,
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

// ── Surface card (bubble / home widget) ─────────────────────────────────────────

/// A card whose hero is a large live preview of the surface's current style.
/// Tapping the preview opens the editor — but only when [editable]; otherwise the
/// preview dims and a one-line hint explains what to switch on. [trailing] holds
/// the surface's own on/off switch (the bubble) or is null (the widget, gated by
/// the counting master). [notice] is a warning line (with a tap action) for a
/// surface that is switched on but cannot actually appear.
class _SurfaceCard extends StatelessWidget {
  const _SurfaceCard({
    required this.title,
    required this.preview,
    required this.editable,
    required this.onEdit,
    this.trailing,
    this.disabledHint,
    this.notice,
    this.onNotice,
    this.previewHeight = 96,
  });

  final String title;
  final Widget preview;
  final bool editable;
  final VoidCallback onEdit;
  final Widget? trailing;
  final String? disabledHint;
  final String? notice;
  final VoidCallback? onNotice;

  /// The preview slot's height — 96 fits the counter surfaces side by side;
  /// the full-width block-screen card gets more room.
  final double previewHeight;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Fixed-height header so the previews line up across the two cards
          // even though only the bubble carries a switch.
          SizedBox(
            height: AppSizes.controlHeight,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: text.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
          const SizedBox(height: AppSpacing.xs),
          // AppPressable, not a bare GestureDetector: the preview is the only
          // way into the editor, so it must announce as a (possibly disabled)
          // button to TalkBack / switch access.
          AppPressable(
            enabled: editable,
            onTap: onEdit,
            semanticLabel: 'Edit $title style',
            child: AnimatedOpacity(
              duration: AppDurations.fast,
              opacity: editable ? 1 : 0.4,
              child: SizedBox(
                height: previewHeight,
                child: Stack(
                  children: [
                    Center(child: preview),
                    if (editable)
                      const Positioned(top: 0, right: 0, child: _EditBadge()),
                  ],
                ),
              ),
            ),
          ),
          if (!editable && disabledHint != null) ...[
            const SizedBox(height: AppSpacing.xs),
            Center(
              child: Text(
                disabledHint!,
                style: text.bodySmall?.copyWith(
                  color: context.glass.onGlassMuted,
                ),
              ),
            ),
          ],
          if (notice != null) ...[
            const SizedBox(height: AppSpacing.xs),
            AppPressable(
              onTap: onNotice ?? () {},
              semanticLabel: notice,
              child: Row(
                children: [
                  const Icon(
                    Icons.warning_amber_rounded,
                    size: 14,
                    color: AppColors.warning,
                  ),
                  const SizedBox(width: AppSpacing.xxs),
                  Expanded(
                    child: Text(
                      notice!,
                      style: text.bodySmall?.copyWith(
                        color: AppColors.warning,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The little accent "edit" affordance pinned to a tappable preview.
class _EditBadge extends StatelessWidget {
  const _EditBadge();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(7),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.secondary,
        shape: BoxShape.circle,
      ),
      child: Icon(
        Icons.tune_rounded,
        size: 16,
        color: Theme.of(context).colorScheme.onSecondary,
      ),
    );
  }
}

// ── Background carousel ─────────────────────────────────────────────────────────

/// The animated-background picker: a horizontally-scrolling row of real SVG
/// previews with the chosen background's name below. The options are
/// theme-specific — dark mode shows the `dark*` backgrounds, light mode shows
/// Aurora + the `light*` backgrounds — and each theme keeps its own pick.
/// Selecting a card updates the app background live behind this screen.
class _BackgroundSection extends StatelessWidget {
  const _BackgroundSection();

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final text = Theme.of(context).textTheme;
    final options = dark ? _darkBackgrounds : _lightBackgrounds;
    return BlocBuilder<SettingsCubit, AppSettings>(
      buildWhen: (a, b) =>
          a.darkBackground != b.darkBackground ||
          a.lightBackground != b.lightBackground,
      builder: (context, settings) {
        final selected = dark
            ? settings.darkBackground
            : settings.lightBackground;
        final current = options.firstWhere(
          (e) => e.$1 == selected,
          orElse: () => options.first,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 84,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                clipBehavior: Clip.none,
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.xxs),
                itemCount: options.length,
                separatorBuilder: (_, _) =>
                    const SizedBox(width: AppSpacing.sm),
                itemBuilder: (context, i) {
                  final b = options[i];
                  return _BgCard(
                    style: b.$1,
                    dark: dark,
                    selected: b.$1 == selected,
                    onTap: () => context.read<SettingsCubit>().setBackground(
                      b.$1,
                      dark: dark,
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              current.$2,
              style: text.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: context.glass.onGlass,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// One background preview card (real SVG, or a gradient for the asset-less
/// Aurora). The SVG is blurred to mirror the full-screen ambient background —
/// which blurs its SVG heavily — so the swatch reads like what actually renders.
/// The selected card animates to an accent ring + glow with a check badge.
/// Same shape as the design system's `VariantCarousel` card, minus the per-card
/// label (the name is shown once below the row) — fold into it if the two
/// ever need to move together.
class _BgCard extends StatelessWidget {
  const _BgCard({
    required this.style,
    required this.dark,
    required this.selected,
    required this.onTap,
  });

  final AppBackground style;
  final bool dark;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final asset = _bgSvgAsset(style);
    final accent = Theme.of(context).colorScheme.secondary;
    final borderWidth = selected ? 2.0 : 1.0;
    final preview = asset == null
        ? DecoratedBox(
            decoration: BoxDecoration(gradient: _auroraSwatchGradient(dark)),
          )
        // Match the ambient background's heavy blur, scaled to the swatch.
        : ImageFiltered(
            imageFilter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: SvgPicture.asset(asset, fit: BoxFit.cover),
          );
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: AppDurations.fast,
        curve: AppCurves.standard,
        width: 116,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: selected ? accent : context.glass.border,
            width: borderWidth,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                    color: accent.withValues(alpha: 0.35),
                    blurRadius: 12,
                  ),
                ]
              : null,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.md - borderWidth),
          child: Stack(
            fit: StackFit.expand,
            children: [
              preview,
              if (selected)
                Positioned(
                  top: 6,
                  right: 6,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: accent,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.check,
                      size: 14,
                      color: Theme.of(context).colorScheme.onSecondary,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Background option data ──────────────────────────────────────────────────────

/// Dark-mode background options (default first). Dark has no Aurora — it's a
/// light-mode ambient.
const _darkBackgrounds = <(AppBackground, String)>[
  (AppBackground.dark1, 'Midnight'),
  (AppBackground.dark2, 'Twilight'),
  (AppBackground.dark3, 'Nebula'),
  (AppBackground.dark4, 'Magenta'),
  (AppBackground.dark5, 'Frost'),
  (AppBackground.dark6, 'Prism'),
];

/// Light-mode background options (Aurora, the theme-aware ambient, is default).
const _lightBackgrounds = <(AppBackground, String)>[
  (AppBackground.aurora, 'Aurora'),
  (AppBackground.light1, 'Sky'),
  (AppBackground.light2, 'Dawn'),
  (AppBackground.light3, 'Blossom'),
  (AppBackground.light4, 'Sunrise'),
  (AppBackground.light5, 'Pastel'),
];

/// SVG asset for a background, or null for Aurora (which has no asset). Mirrors
/// `svgAssetFor` in the design system — the presentation layer can't reach
/// `main.dart`'s domain→style mapper, so a small local copy keeps the picker
/// self-contained.
String? _bgSvgAsset(AppBackground style) => switch (style) {
  AppBackground.aurora => null,
  AppBackground.dark1 => 'assets/images/bg/dark_bg1.svg',
  AppBackground.dark2 => 'assets/images/bg/dark_bg2.svg',
  AppBackground.dark3 => 'assets/images/bg/dark_bg3.svg',
  AppBackground.dark4 => 'assets/images/bg/dark_bg4.svg',
  AppBackground.dark5 => 'assets/images/bg/dark_bg5.svg',
  AppBackground.dark6 => 'assets/images/bg/dark_bg6.svg',
  AppBackground.light1 => 'assets/images/bg/light_bg1.svg',
  AppBackground.light2 => 'assets/images/bg/light_bg2.svg',
  AppBackground.light3 => 'assets/images/bg/light_bg3.svg',
  AppBackground.light4 => 'assets/images/bg/light_bg4.svg',
  AppBackground.light5 => 'assets/images/bg/light_bg5.svg',
};

/// A small gradient standing in for the (asset-less) Aurora background in its
/// picker swatch.
Gradient _auroraSwatchGradient(bool dark) => LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: dark
      ? const [Color(0xFF1E2A52), Color(0xFF3A2A78), Color(0xFF0B1326)]
      : const [Color(0xFFF1ECFF), Color(0xFFE6FBF6), Color(0xFFEEF1FB)],
);
