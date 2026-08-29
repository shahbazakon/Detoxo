import 'dart:math' as math;

import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/core/utils/duration_format.dart';
import 'package:flutter/material.dart';

/// An interactive radial gauge for picking a daily short-form-video limit —
/// drag (or tap) anywhere on the 270° arc to set the value, which animates in
/// the centre. Deliberately mirrors the dashboard's screen-time ring so the
/// number the user sets here reads as "the ring you'll fill each day".
///
/// Controlled: it renders [value] and reports drags via [onChanged]; the parent
/// owns the state. Accessible via a Semantics slider (increase/decrease step).
class ScreenTimeDial extends StatefulWidget {
  const ScreenTimeDial({
    required this.value,
    required this.onChanged,
    this.min = const Duration(minutes: 15),
    this.max = const Duration(hours: 5),
    this.step = const Duration(minutes: 15),
    this.accent,
    this.size = 260,
    super.key,
  });

  final Duration value;
  final ValueChanged<Duration> onChanged;
  final Duration min;
  final Duration max;
  final Duration step;
  final Color? accent;
  final double size;

  @override
  State<ScreenTimeDial> createState() => _ScreenTimeDialState();
}

class _ScreenTimeDialState extends State<ScreenTimeDial> {
  // 270° gauge with a gap at the bottom (canvas convention: 0 rad = 3 o'clock,
  // angle increases clockwise because y grows downward).
  static const double _startAngle = math.pi * 3 / 4; // down-left
  static const double _sweepAngle = math.pi * 3 / 2; // 270°

  bool _interacted = false;

  int get _minM => widget.min.inMinutes;
  int get _maxM => widget.max.inMinutes;

  double get _fraction =>
      ((widget.value.inMinutes - _minM) / (_maxM - _minM)).clamp(0.0, 1.0);

  /// Maps a touch point to a 0..1 position along the arc and commits it.
  void _handle(Offset local) {
    final c = widget.size / 2;
    final v = Offset(local.dx - c, local.dy - c);
    if (v.distance < widget.size * 0.22) return; // ignore the dead centre
    var a = (math.atan2(v.dy, v.dx) - _startAngle) % (2 * math.pi);
    if (a < 0) a += 2 * math.pi;
    final double fraction;
    if (a <= _sweepAngle) {
      fraction = a / _sweepAngle;
    } else {
      // In the bottom gap — snap to whichever end is nearer.
      fraction = (a - _sweepAngle) < (2 * math.pi - a) ? 1.0 : 0.0;
    }
    _commit(fraction);
  }

  void _commit(double fraction) {
    final stepM = widget.step.inMinutes;
    final raw = _minM + fraction.clamp(0.0, 1.0) * (_maxM - _minM);
    final snapped = ((raw / stepM).round() * stepM).clamp(_minM, _maxM);
    final next = Duration(minutes: snapped);
    if (next != widget.value) {
      AppHaptics.selection();
      widget.onChanged(next);
    }
  }

  void _nudge(int steps) =>
      _commit(_fraction + steps * widget.step.inMinutes / (_maxM - _minM));

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Semantics(
      slider: true,
      label: 'Daily limit',
      value: formatHm(widget.value),
      onIncrease: () => _nudge(1),
      onDecrease: () => _nudge(-1),
      child: GestureDetector(
        onTapDown: (d) {
          setState(() => _interacted = true);
          _handle(d.localPosition);
        },
        onPanStart: (d) {
          setState(() => _interacted = true);
          _handle(d.localPosition);
        },
        onPanUpdate: (d) => _handle(d.localPosition),
        child: SizedBox(
          width: widget.size,
          height: widget.size,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Animate the arc/thumb to the snapped position; the centre text
              // updates immediately.
              TweenAnimationBuilder<double>(
                tween: Tween<double>(end: _fraction),
                duration: AppDurations.fast,
                curve: AppCurves.standard,
                builder: (context, f, _) => CustomPaint(
                  size: Size.square(widget.size),
                  painter: _DialPainter(
                    fraction: f,
                    accent:
                        widget.accent ??
                        Theme.of(context).colorScheme.secondary,
                    trackColor: context.glass.border,
                  ),
                ),
              ),
              _center(context, text),
            ],
          ),
        ),
      ),
    );
  }

  Widget _center(BuildContext context, TextTheme text) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'PER DAY',
          style: text.labelSmall?.copyWith(
            color: widget.accent ?? Theme.of(context).colorScheme.secondary,
            letterSpacing: 2,
            fontSize: 11,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        ShaderMask(
          shaderCallback: (b) => context.metricGradient.createShader(b),
          blendMode: BlendMode.srcIn,
          child: Text(
            formatHm(widget.value),
            style: text.displaySmall?.copyWith(
              fontWeight: FontWeight.w800,
              height: 1,
              color: Colors.white,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        AnimatedOpacity(
          duration: AppDurations.normal,
          opacity: _interacted ? 0 : 1,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.touch_app_outlined,
                size: 14,
                color: context.glass.onGlassMuted,
              ),
              const SizedBox(width: 4),
              Text(
                'Drag to set',
                style: text.labelSmall?.copyWith(
                  color: context.glass.onGlassMuted,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DialPainter extends CustomPainter {
  _DialPainter({
    required this.fraction,
    required this.accent,
    required this.trackColor,
  });

  final double fraction;
  final Color accent;
  final Color trackColor;

  static const double _start = math.pi * 3 / 4;
  static const double _sweep = math.pi * 3 / 2;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.075;
    final center = size.center(Offset.zero);
    final radius = (size.width - stroke) / 2 - 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    // Faint full-gauge track.
    canvas.drawArc(
      rect,
      _start,
      _sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round
        ..color = trackColor,
    );

    final sweep = _sweep * fraction.clamp(0.0, 1.0);
    if (fraction > 0) {
      canvas
        // Ambient bloom behind the fill.
        ..drawArc(
          rect,
          _start,
          sweep,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke + 6
            ..strokeCap = StrokeCap.round
            ..color = accent.withValues(alpha: 0.30)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
        )
        // Bright brand-gradient fill.
        ..drawArc(
          rect,
          _start,
          sweep,
          false,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke
            ..strokeCap = StrokeCap.round
            ..shader = AppGradients.metric.createShader(rect),
        );
    }

    // Draggable thumb: glow, white knob, accent ring.
    final ang = _start + sweep;
    final tip = center + Offset(math.cos(ang), math.sin(ang)) * radius;
    canvas
      ..drawCircle(
        tip,
        stroke * 0.85,
        Paint()
          ..color = accent.withValues(alpha: 0.45)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
      )
      ..drawCircle(tip, stroke * 0.6, Paint()..color = Colors.white)
      ..drawCircle(
        tip,
        stroke * 0.6,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..color = accent,
      );
  }

  @override
  bool shouldRepaint(_DialPainter old) =>
      old.fraction != fraction || old.accent != accent;
}
