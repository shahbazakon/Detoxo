/// How an app or website tends to affect focus — the catalog's one behavioural
/// axis. Rules block by it (M3), stats split screen time by it (M4), the soft
/// nudge fires on it (M7).
enum AppBehavior {
  distracting('distracting', 'Distracting'),
  productive('productive', 'Productive'),
  neutral('neutral', 'Neutral');

  const AppBehavior(this.wire, this.label);

  final String wire;
  final String label;

  /// An unknown or absent token is [neutral]: a typo in the seed must never
  /// promote an app to "distracting" and start blocking it.
  static AppBehavior fromWire(String? wire) => values.firstWhere(
    (b) => b.wire == wire,
    orElse: () => AppBehavior.neutral,
  );
}
