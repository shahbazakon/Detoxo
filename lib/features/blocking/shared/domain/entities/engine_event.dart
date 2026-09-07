import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
import 'package:equatable/equatable.dart';

/// Live status of the native engine plus block counters, streamed to the UI.
///
/// Every count here is the engine's own (`ConfigStore.recordBlock`), which
/// keeps counting with the UI dead and rolls over at midnight natively — the
/// only complete record of what Detoxo blocked.
class ServiceSnapshot extends Equatable {
  const ServiceSnapshot({
    this.status = ServiceStatus.unknown,
    this.blocksToday = 0,
    this.blocksTotal = 0,
    this.blocksYesterday = 0,
    this.blocksByPackage = const {},
  });

  final ServiceStatus status;
  final int blocksToday;
  final int blocksTotal;

  /// Yesterday's finished total — a neutral reference beside the running one
  /// (EVO-060). `0` when the last recorded day is older than yesterday.
  final int blocksYesterday;

  /// Today's blocks per package — the engine's own bounded tally (EVO-059),
  /// empty before the day's first block and never naming a protected app.
  final Map<String, int> blocksByPackage;

  ServiceSnapshot copyWith({
    ServiceStatus? status,
    int? blocksToday,
    int? blocksTotal,
    int? blocksYesterday,
    Map<String, int>? blocksByPackage,
  }) => ServiceSnapshot(
    status: status ?? this.status,
    blocksToday: blocksToday ?? this.blocksToday,
    blocksTotal: blocksTotal ?? this.blocksTotal,
    blocksYesterday: blocksYesterday ?? this.blocksYesterday,
    blocksByPackage: blocksByPackage ?? this.blocksByPackage,
  );

  @override
  List<Object?> get props => [
    status,
    blocksToday,
    blocksTotal,
    blocksYesterday,
    blocksByPackage,
  ];
}

/// A single block event emitted by the native engine over the EventChannel.
class BlockEvent extends Equatable {
  const BlockEvent({
    required this.platformId,
    required this.packageName,
    required this.mode,
    required this.timestamp,
    this.wall = false,
  });

  final String platformId;
  final String packageName;

  /// The navigation performed. `BLOCK_SCREEN` is a wall policy, so a block in
  /// that mode reports `pressBack` here and `wall == true`.
  final BlockingMode mode;
  final DateTime timestamp;

  /// Whether the block screen was actually shown for this block (EVO-057).
  final bool wall;

  @override
  List<Object?> get props => [platformId, packageName, mode, timestamp, wall];
}
