import 'package:equatable/equatable.dart';

/// The two `UsageEvents.Event` types native lets through. [raw] is the OS
/// constant; the wire carries the int so Dart never depends on Android's enum.
enum UsageEventType {
  /// An app came to the front — drives context switches and distraction opens.
  moveToForeground(1),

  /// The screen became interactive — a device pickup.
  screenInteractive(18);

  const UsageEventType(this.raw);

  final int raw;

  /// Null for any type the layer does not model; the row is dropped, not
  /// mis-filed.
  static UsageEventType? fromRaw(int? raw) {
    for (final t in values) {
      if (t.raw == raw) return t;
    }
    return null;
  }
}

/// One usage event, ascending as the OS yields them.
class UsageEvent extends Equatable {
  const UsageEvent({
    required this.package,
    required this.type,
    required this.timestampMillis,
  });

  /// Null when the row carries a type this layer does not model or no package.
  static UsageEvent? fromChannel(Map<String, dynamic> m) {
    final type = UsageEventType.fromRaw((m['type'] as num?)?.toInt());
    final package = m['package'] as String? ?? '';
    if (type == null || package.isEmpty) return null;
    return UsageEvent(
      package: package,
      type: type,
      timestampMillis: (m['timestampMillis'] as num?)?.toInt() ?? 0,
    );
  }

  final String package;
  final UsageEventType type;
  final int timestampMillis;

  DateTime get at => DateTime.fromMillisecondsSinceEpoch(timestampMillis);

  @override
  List<Object?> get props => [package, type, timestampMillis];
}
