import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/features/content_counter/content_counter_appearance/presentation/widgets/bubble_preview.dart';
import 'package:detoxo/features/content_counter/content_counter_bubble/domain/entities/bubble_style.dart';
import 'package:detoxo/features/content_counter/content_counter_core/domain/entities/counter_appearance.dart';
import 'package:detoxo/features/content_counter/content_counter_core/domain/entities/counter_style_enums.dart';
import 'package:detoxo/features/content_counter/content_counter_core/presentation/content_counter_cubit.dart';
import 'package:detoxo/features/content_counter/content_counter_core/presentation/counter_appearance_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Live-preview customization for the floating counter bubble: pick a variant,
/// then tune size / text / spacing / opacity — the pinned preview and (if the
/// bubble is on screen) the real overlay update as you go. Reads the app-wide
/// `CounterAppearanceCubit` (shared with the Appearance hub).
class BubbleStyleScreen extends StatelessWidget {
  const BubbleStyleScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const GlassScaffold(
      appBar: GlassAppBar(title: Text('Bubble style')),
      body: SafeArea(child: _Body()),
    );
  }
}

class _Body extends StatefulWidget {
  const _Body();

  @override
  State<_Body> createState() => _BodyState();
}

class _BodyState extends State<_Body> {
  // The preview scrubs across the usage range so the color/emoji variants are
  // legible even before the user has watched anything today.
  double _previewCount = 137;

  // Representative today-watch-time for the tap-reveal demo (replaced with the
  // real value once loaded), so the stopwatch format is visible immediately.
  Duration _previewTime = const Duration(hours: 1, minutes: 23, seconds: 45);

  @override
  void initState() {
    super.initState();
    // Seed from the live count once; the slider owns the figure from here.
    final count = context.read<ContentCounterCubit>().state;
    if (count.today > 0) _previewCount = count.today.toDouble();
    if (count.timeToday > Duration.zero) _previewTime = count.timeToday;
  }

  void _setStyle(BubbleStyle style) =>
      context.read<CounterAppearanceCubit>().setBubble(style);

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<CounterAppearanceCubit, CounterAppearance>(
      builder: (context, appearance) {
        final style = appearance.bubble;
        final count = _previewCount.round();
        return ListView(
          padding: EdgeInsets.fromLTRB(
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.md,
            AppSpacing.md + MediaQuery.viewPaddingOf(context).bottom,
          ),
          children: [
            _PreviewStage(style: style, count: count),
            const SizedBox(height: AppSpacing.sm),
            _LabeledSlider(
              label: 'Preview count',
              value: _previewCount,
              min: 0,
              max: 500,
              divisions: 10,
              format: (v) => '${v.round()} reels',
              onChanged: (v) => setState(() => _previewCount = v),
            ),
            const SizedBox(height: AppSpacing.md),
            const SectionHeader('Style'),
            VariantCarousel(
              options: [
                for (final v in BubbleVariant.values)
                  VariantOption(
                    label: _variantLabel(v),
                    selected: style.variant == v,
                    onTap: () => _setStyle(style.copyWith(variant: v)),
                    preview: BubblePreview(
                      style: style.copyWith(variant: v),
                      count: count,
                      area: 64,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.md),
            const SectionHeader('Customize'),
            _LabeledSlider(
              label: 'Size',
              value: style.size,
              min: BubbleStyle.sizeMin,
              max: BubbleStyle.sizeMax,
              divisions: 8,
              format: (v) => '${v.round()} dp',
              onChanged: (v) => _setStyle(style.copyWith(size: v)),
            ),
            _LabeledSlider(
              label: 'Text size',
              value: style.textScale,
              min: BubbleStyle.textScaleMin,
              max: BubbleStyle.textScaleMax,
              divisions: 6,
              format: _percent,
              onChanged: (v) => _setStyle(style.copyWith(textScale: v)),
            ),
            if (style.variant == BubbleVariant.minimalPill)
              _LabeledSlider(
                label: 'Spacing',
                value: style.spacing,
                min: BubbleStyle.spacingMin,
                max: BubbleStyle.spacingMax,
                divisions: 5,
                format: _percent,
                onChanged: (v) => _setStyle(style.copyWith(spacing: v)),
              ),
            _LabeledSlider(
              label: 'Opacity',
              value: style.opacity,
              min: BubbleStyle.opacityMin,
              max: BubbleStyle.opacityMax,
              divisions: 5,
              format: _percent,
              onChanged: (v) => _setStyle(style.copyWith(opacity: v)),
            ),
            const SizedBox(height: AppSpacing.xs),
            AppToggleTile(
              leading: const IconBadge(icon: Icons.short_text_rounded),
              title: 'Show caption',
              subtitle: 'A tiny “reels” label under the count',
              value: style.showLabel,
              onChanged: (v) => _setStyle(style.copyWith(showLabel: v)),
            ),
            AppToggleTile(
              leading: const IconBadge(icon: Icons.schedule_rounded),
              title: 'Show time on tap',
              subtitle:
                  'Tap the bubble to reveal today’s watch time '
                  '(double-tap opens the app)',
              value: style.showTime,
              onChanged: (v) => _setStyle(style.copyWith(showTime: v)),
            ),
            if (style.showTime) ...[
              const SizedBox(height: AppSpacing.sm),
              _TapRevealDemo(style: style, time: _previewTime),
            ],
          ],
        );
      },
    );
  }
}

String _percent(double v) => '${(v * 100).round()}%';

class _PreviewStage extends StatelessWidget {
  const _PreviewStage({required this.style, required this.count});

  final BubbleStyle style;
  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 168,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [context.glass.fillTop, context.glass.fillBottom],
        ),
        border: Border.all(color: context.glass.border),
      ),
      child: BubblePreview(style: style, count: count),
    );
  }
}

/// Shows what a single tap reveals: the bubble flipped to today's watch time in
/// the stopwatch format (`45s` / `mm:ss` / `hh:mm:ss`), mirroring the overlay.
class _TapRevealDemo extends StatelessWidget {
  const _TapRevealDemo({required this.style, required this.time});

  final BubbleStyle style;
  final Duration time;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadius.lg),
        color: context.glass.fillTop,
        border: Border.all(color: context.glass.border),
      ),
      child: Row(
        children: [
          BubblePreview(style: style, count: 0, time: time, area: 64),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'On single tap',
                  style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  'The bubble briefly shows today’s time '
                  '(${formatBubbleClock(time)}), then reverts to the count.',
                  style: text.bodySmall?.copyWith(
                    color: context.glass.onGlassMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String _variantLabel(BubbleVariant v) => switch (v) {
  BubbleVariant.glassOrb => 'Glass orb',
  BubbleVariant.usageRing => 'Usage ring',
  BubbleVariant.emojiMood => 'Emoji mood',
  BubbleVariant.minimalPill => 'Minimal pill',
};

/// A compact title + value row over an [AdaptiveSlider]. [format] renders the
/// value both for the visible label and for screen readers, so they agree.
class _LabeledSlider extends StatelessWidget {
  const _LabeledSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.format,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String Function(double value) format;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              Text(
                format(value),
                style: text.bodySmall?.copyWith(
                  color: context.glass.onGlassMuted,
                ),
              ),
            ],
          ),
          Semantics(
            label: label,
            child: AdaptiveSlider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              semanticFormatter: format,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }
}
