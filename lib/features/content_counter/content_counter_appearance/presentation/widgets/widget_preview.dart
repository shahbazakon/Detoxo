import 'package:detoxo/features/content_counter/content_counter_appearance/presentation/widgets/widget_palette.dart';
import 'package:detoxo/features/content_counter/content_counter_core/domain/entities/counter_style_enums.dart';
import 'package:detoxo/features/content_counter/content_counter_core/domain/usage_ladder.dart';
import 'package:detoxo/features/content_counter/home_content_counter/domain/entities/widget_style.dart';
import 'package:flutter/material.dart';

/// Flutter mirror of the native `WidgetBitmapRenderer` — the declared source of
/// truth for the home widget's look. Renders the 2×2 face (glass background +
/// centered count lines) for a [WidgetStyle] in a square box, resolving a
/// `system` theme from the current app brightness.
class WidgetPreview extends StatelessWidget {
  const WidgetPreview({
    required this.style,
    required this.today,
    required this.total,
    this.size = 148,
    super.key,
  });

  final WidgetStyle style;
  final int today;
  final int total;
  final double size;

  @override
  Widget build(BuildContext context) {
    final dark = switch (style.theme) {
      WidgetTheme.light => false,
      WidgetTheme.dark => true,
      WidgetTheme.system => Theme.of(context).brightness == Brightness.dark,
    };
    // A CustomPaint has no semantics of its own; describe what the picture
    // shows so a screen-reader user learns what the widget will look like.
    return Semantics(
      label: 'Home widget preview: $today reels today, $total all time',
      excludeSemantics: true,
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _WidgetFacePainter(
            style: style,
            today: today,
            total: total,
            dark: dark,
          ),
        ),
      ),
    );
  }
}

/// MIRROR CONTRACT: every size ratio below reproduces the native
/// `WidgetBitmapRenderer` (`widget/WidgetBitmapRenderer.kt`) — the declared
/// source of truth; the colours come from the shared [widgetPaletteFor]. Edit
/// the Kotlin first, then mirror here.
class _WidgetFacePainter extends CustomPainter {
  _WidgetFacePainter({
    required this.style,
    required this.today,
    required this.total,
    required this.dark,
  });

  final WidgetStyle style;
  final int today;
  final int total;
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final unit = size.shortestSide;
    final strokeW = (unit * 0.012).clamp(1.0, 6.0);
    final corner = unit * 0.16;
    final rect = Rect.fromLTRB(
      strokeW / 2,
      strokeW / 2,
      size.width - strokeW / 2,
      size.height - strokeW / 2,
    );
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(corner));
    final p = widgetPaletteFor(style.background, dark: dark, today: today);

    canvas
      ..drawRRect(
        rrect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [p.bgTop, p.bgBottom],
          ).createShader(rect),
      )
      ..drawRRect(
        rrect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeW
          ..color = p.stroke,
      );

    _drawLines(canvas, size, unit, p);
  }

  void _drawLines(Canvas canvas, Size size, double unit, WidgetPalette p) {
    final cozy = style.density != WidgetDensity.compact;
    final todayColor = style.accentByUsage ? bandColorFor(today) : p.today;
    final painters = <TextPainter>[];
    if (style.showToday) {
      painters.add(
        _line(
          '$today',
          unit * (cozy ? 0.34 : 0.30),
          FontWeight.w700,
          todayColor,
        ),
      );
    }
    if (style.showLabel) {
      painters.add(
        _line(
          'reels today',
          unit * (cozy ? 0.105 : 0.095),
          FontWeight.w500,
          p.label,
        ),
      );
    }
    if (style.showTotal) {
      painters.add(
        _line(
          'All time · $total',
          unit * (cozy ? 0.088 : 0.080),
          FontWeight.w500,
          p.total,
        ),
      );
    }
    if (painters.isEmpty) return;

    final gap = unit * 0.05;
    final blockH =
        painters.fold<double>(0, (a, tp) => a + tp.height) +
        gap * (painters.length - 1);
    var y = (size.height - blockH) / 2;
    for (final tp in painters) {
      tp.paint(canvas, Offset((size.width - tp.width) / 2, y));
      y += tp.height + gap;
    }
  }

  TextPainter _line(
    String text,
    double fontSize,
    FontWeight weight,
    Color color,
  ) {
    return TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: color,
          fontSize: fontSize,
          fontWeight: weight,
          height: 1.1,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
  }

  @override
  bool shouldRepaint(_WidgetFacePainter old) =>
      old.style != style ||
      old.today != today ||
      old.total != total ||
      old.dark != dark;
}
