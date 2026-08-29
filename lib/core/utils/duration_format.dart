/// "Xh Ym", dropping an empty half: `3h 12m`, `3h`, `12m`.
///
/// The app's **one** spoken form for a span of screen time — the dashboard
/// hero, the insights metrics and the onboarding limit dial all render through
/// this, so the same Duration can never read two ways. Mirrored in Kotlin by
/// `UsageQuery.formatHm` for the block screen.
///
/// Seconds are truncated, never rounded up: a wall that claims time which has
/// not passed is a small lie in the wrong direction.
String formatHm(Duration d) {
  final total = d.inMinutes < 0 ? 0 : d.inMinutes;
  final h = total ~/ 60;
  final m = total % 60;
  if (h == 0) return '${m}m';
  return m == 0 ? '${h}h' : '${h}h ${m}m';
}
