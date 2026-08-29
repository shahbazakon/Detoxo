import 'package:equatable/equatable.dart';

/// One app's foreground time inside a queried window, straight from the OS.
class AppUsage extends Equatable {
  const AppUsage({required this.package, required this.foregroundMillis});

  factory AppUsage.fromChannel(Map<String, dynamic> m) => AppUsage(
    package: m['package'] as String? ?? '',
    foregroundMillis: (m['foregroundMillis'] as num?)?.toInt() ?? 0,
  );

  final String package;
  final int foregroundMillis;

  Duration get foreground => Duration(milliseconds: foregroundMillis);

  @override
  List<Object?> get props => [package, foregroundMillis];
}
