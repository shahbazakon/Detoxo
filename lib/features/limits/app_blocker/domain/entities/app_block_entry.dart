import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
import 'package:equatable/equatable.dart';

/// Why an add succeeded or was refused — consumed by the add flow's toast so
/// a refused add never masquerades as success.
enum AppBlockAddResult {
  added,

  /// Not a plausible package id (see `isValidPackageName`).
  invalid,

  /// A sensitive-catalog app — may never be blocked, whatever the entry path.
  sensitive,

  /// Already in the custom blocklist.
  duplicate,

  /// The save failed; the list was reverted and nothing reached native.
  failed,
}

/// A fully-blocked app (PIN-locked or daily-limited).
class AppBlockEntry extends Equatable {
  const AppBlockEntry({
    required this.packageName,
    required this.appName,
    this.enabled = true,
    this.lockAction = AppLockAction.closeApp,
    this.dailyLimitMinutes = 0,
  });

  factory AppBlockEntry.fromJson(Map<String, dynamic> json) => AppBlockEntry(
    packageName: json['packageName'] as String? ?? '',
    appName: json['appName'] as String? ?? '',
    enabled: json['enabled'] as bool? ?? true,
    lockAction: AppLockAction.fromWire(json['lockAction'] as String?),
    dailyLimitMinutes: json['dailyLimitMinutes'] as int? ?? 0,
  );

  final String packageName;
  final String appName;
  final bool enabled;
  final AppLockAction lockAction;
  final int dailyLimitMinutes;

  AppBlockEntry copyWith({
    bool? enabled,
    AppLockAction? lockAction,
    int? dailyLimitMinutes,
  }) => AppBlockEntry(
    packageName: packageName,
    appName: appName,
    enabled: enabled ?? this.enabled,
    lockAction: lockAction ?? this.lockAction,
    dailyLimitMinutes: dailyLimitMinutes ?? this.dailyLimitMinutes,
  );

  Map<String, dynamic> toJson() => {
    'packageName': packageName,
    'appName': appName,
    'enabled': enabled,
    'lockAction': lockAction.wire,
    'dailyLimitMinutes': dailyLimitMinutes,
  };

  @override
  List<Object?> get props => [
    packageName,
    appName,
    enabled,
    lockAction,
    dailyLimitMinutes,
  ];
}
