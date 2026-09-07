import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
import 'package:equatable/equatable.dart';

/// A user-facing, blockable content surface (e.g. "Instagram Reels"), derived
/// from the platform config. Drives the dashboard blocklist toggles.
class BlockTarget extends Equatable {
  const BlockTarget({
    required this.platformId,
    required this.packageName,
    required this.appName,
    required this.displayName,
    required this.iconUrl,
    required this.detectionType,
    required this.premiumExclusive,
    required this.defaultEnabled,
    required this.isBrowser,
    this.isInstalled = true,
  });

  final String platformId;
  final String packageName;
  final String appName;
  final String displayName;
  final String iconUrl;
  final DetectionType detectionType;
  final bool premiumExclusive;
  final bool defaultEnabled;
  final bool isBrowser;

  /// Whether the owning app is installed on this device. `true` when install
  /// state is unknown (off-Android), so the full list renders interactively.
  /// Drives the greyed-out "Not installed" treatment in the blocklist.
  final bool isInstalled;

  @override
  List<Object?> get props => [
    platformId,
    packageName,
    displayName,
    isInstalled,
  ];
}
