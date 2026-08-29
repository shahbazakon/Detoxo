import 'dart:math' as math;

import 'package:detoxo/features/content_counter/content_counter_bubble/domain/entities/bubble_style.dart';
import 'package:detoxo/features/content_counter/content_counter_core/domain/entities/counter_style_enums.dart';
import 'package:detoxo/features/content_counter/content_counter_core/domain/usage_ladder.dart';
import 'package:flutter/material.dart';

/// Flutter mirror of the native `BubbleView` — the declared source of truth for
/// how the bubble looks. Renders any [BubbleStyle] variant at its real size,
/// centered in a fixed preview area, using the shared `usage_ladder` so the
/// preview matches the on-screen bubble at the same count.
class BubblePreview extends StatelessWidget {
  const BubblePreview({
    required this.style,
    required this.count,
    this.area = 132,
    this.time,
    super.key,
  });

  final BubbleStyle style;
  final int count;

  /// Side of the square preview area the bubble floats in.
  final double area;

  /// When set, the preview renders this tap-revealed watch time (stopwatch
  /// format) in place of the count — mirroring the native single-tap reveal.
  final Duration? time;

  @override
  Widget build(BuildContext context) {
    final t = time;
    // A CustomPaint has no semantics of its own; describe what the picture
    // shows so a screen-reader user learns what the bubble will look like.
    return Semantics(
      label:
          'Bubble preview, ${_variantName(style.variant)}: '
          '${t != null ? '${formatBubbleClock(t)} today' : '$count reels'}',
      excludeSemantics: true,
      child: Center(
        child: SizedBox(
          width: area,
          height: area,
          child: CustomPaint(
            painter: _BubblePainter(style: style, count: count, time: t),
          ),
        ),
      ),
    );
  }

  static String _variantName(BubbleVariant v) => switch (v) {
    BubbleVariant.glassOrb => 'glass orb',
    BubbleVariant.usageRing => 'usage ring',
    BubbleVariant.emojiMood => 'emoji mood',
    BubbleVariant.minimalPill => 'minimal pill',
  };
}

/// Stopwatch label for the bubble's tap-revealed time — `45s` / `3:05` /
/// `1:23:45`. MIRROR CONTRACT: must stay byte-for-byte equal to the native
/// `BubbleView.formatMs` in `overlay/ContentCounterBubble.kt` (pinned by
/// `test/counter_style_test.dart`); change both or neither.
String formatBubbleClock(Duration d) {
  final totalSec = d.inSeconds;
  final h = totalSec ~/ 3600;
  final m = (totalSec % 3600) ~/ 60;
  final s = totalSec % 60;
  final ss = s.toString().padLeft(2, '0');
  if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:$ss';
  if (m > 0) return '$m:$ss';
  return '${s}s';
}

class _BubblePainter extends CustomPainter {
  _BubblePainter({required this.style, required this.count, this.time});

  final BubbleStyle style;
  final int count;
  final Duration? time;

  // MIRROR CONTRACT: these literals and every geometry ratio below reproduce
  // the native `BubbleView` (`overlay/ContentCounterBubble.kt`) — the declared
  // source of truth. Edit the Kotlin first, then mirror here.
  static const int _fillTop = 0xF21C2544;
  static const int _fillBottom = 0xF20B1326;
  static const int _seed = 0xFF6D3BD7;
  static const int _accent = 0xFF44E2CD;
  static const int _glow = 0x8044E2CD;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final diameter = style.size;
    final r = diameter / 2;

    switch (style.variant) {
      case BubbleVariant.usageRing:
        _drawUsageRing(canvas, center, r);
      case BubbleVariant.emojiMood:
        _drawEmoji(canvas, center, r);
      case BubbleVariant.minimalPill:
        _drawPill(canvas, center, diameter);
      case BubbleVariant.glassOrb:
        _drawOrb(canvas, center, r);
    }
  }

  // ── Variants ────────────────────────────────────────────────────────────────

  void _drawOrb(Canvas canvas, Offset c, double r) {
    _glowCircle(canvas, c, r);
    _fillCircle(canvas, c, r);
    _brandRing(canvas, c, r);
    _drawCount(canvas, c, r);
  }

  void _drawUsageRing(Canvas canvas, Offset c, double r) {
    _fillCircle(canvas, c, r);
    final ringStroke = r * 0.16;
    final rr = r - ringStroke;
    final rect = Rect.fromCircle(center: c, radius: rr);
    canvas.drawArc(
      rect,
      0,
      math.pi * 2,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = ringStroke
        ..color = const Color(0x22FFFFFF),
    );
    if (count > 0) {
      final sweep = count.clamp(0, kUsageCap) / kUsageCap * math.pi * 2;
      canvas.drawArc(
        rect,
        -math.pi / 2,
        math.max(sweep, 0.14),
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = ringStroke
          ..color = bandColorFor(count),
      );
    }
    _drawCount(canvas, c, r);
  }

  void _drawEmoji(Canvas canvas, Offset c, double r) {
    _glowCircle(canvas, c, r);
    _fillCircle(canvas, c, r);
    _brandRing(canvas, c, r);
    if (time != null) {
      _drawCount(canvas, c, r); // tap reveal shows the time, not the mood
      return;
    }
    _text(
      canvas,
      emojiFor(count),
      c.translate(0, -r * 0.12),
      TextStyle(fontSize: r * 0.78),
    );
    _text(
      canvas,
      '$count',
      c.translate(0, r * 0.52),
      TextStyle(
        color: Colors.white,
        fontSize: r * 0.30 * style.textScale,
        fontWeight: FontWeight.w700,
      ),
    );
  }

  void _drawPill(Canvas canvas, Offset c, double diameter) {
    final label = time != null ? formatBubbleClock(time!) : '$count';
    final h = diameter * 0.66;
    final dotR = h * 0.15;
    final padH = h * 0.32 * style.spacing;
    final gap = h * 0.20 * style.spacing;
    final textStyle = TextStyle(
      color: Colors.white,
      fontSize: h * 0.42 * style.textScale,
      fontWeight: FontWeight.w700,
    );
    final tp = _layout(label, textStyle);
    final width = padH + dotR * 2 + gap + tp.width + padH;

    final rect = Rect.fromCenter(center: c, width: width, height: h);
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(h / 2));
    canvas
      ..drawRRect(rrect, _fillPaint(rect))
      ..drawRRect(rrect, _ringPaint(rect));

    final dotCx = rect.left + padH + dotR;
    canvas.drawCircle(
      Offset(dotCx, c.dy),
      dotR,
      Paint()..color = bandColorFor(count),
    );
    tp.paint(canvas, Offset(dotCx + dotR + gap, c.dy - tp.height / 2));
  }

  // ── Shared bits ──────────────────────────────────────────────────────────────

  void _drawCount(Canvas canvas, Offset c, double r) {
    final t = time;
    final label = t != null ? formatBubbleClock(t) : '$count';
    final factor = label.length >= 6
        ? 0.40
        : label.length >= 4
        ? 0.52
        : label.length == 3
        ? 0.62
        : 0.75;
    final countStyle = TextStyle(
      color: Colors.white,
      fontWeight: FontWeight.w700,
      fontSize: r * factor * style.textScale,
    );
    // Two-line layout for the "reels" caption or the tap-revealed time.
    if (style.showLabel || t != null) {
      _text(canvas, label, c.translate(0, -r * 0.16), countStyle);
      _text(
        canvas,
        t != null ? 'today' : 'reels',
        c.translate(0, r * 0.44),
        TextStyle(color: Colors.white70, fontSize: r * 0.26),
      );
    } else {
      _text(canvas, label, c, countStyle);
    }
  }

  Paint _fillPaint(Rect rect) => Paint()
    ..shader = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [_withOpacity(_fillTop), _withOpacity(_fillBottom)],
    ).createShader(rect);

  Paint _ringPaint(Rect rect) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 2
    ..shader = const LinearGradient(
      colors: [Color(_seed), Color(_accent)],
    ).createShader(rect);

  void _fillCircle(Canvas canvas, Offset c, double r) {
    final rect = Rect.fromCircle(center: c, radius: r);
    canvas.drawCircle(c, r, _fillPaint(rect));
  }

  void _brandRing(Canvas canvas, Offset c, double r) {
    final rect = Rect.fromCircle(center: c, radius: r);
    canvas.drawCircle(c, r - 1, _ringPaint(rect));
  }

  void _glowCircle(Canvas canvas, Offset c, double r) {
    canvas.drawCircle(
      c.translate(0, 1.5),
      r,
      Paint()
        ..color = const Color(_glow)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
  }

  void _text(Canvas canvas, String text, Offset center, TextStyle style) {
    final tp = _layout(text, style);
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  TextPainter _layout(String text, TextStyle style) => TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
  )..layout();

  Color _withOpacity(int argb) {
    final base = Color(argb);
    return base.withValues(alpha: (base.a * style.opacity).clamp(0.0, 1.0));
  }

  @override
  bool shouldRepaint(_BubblePainter old) =>
      old.style != style || old.count != count || old.time != time;
}
