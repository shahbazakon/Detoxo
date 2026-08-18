import 'dart:typed_data';

import 'package:equatable/equatable.dart';

/// A user-launchable app reported by the native engine's `installedApps`
/// command: display label, package name and an optional 96px PNG icon.
///
/// `icon` is null for manual (typed) entries and per-app icon-load failures —
/// UI falls back to the letter tile.
class InstalledApp extends Equatable {
  const InstalledApp({
    required this.packageName,
    required this.appName,
    this.icon,
  });

  factory InstalledApp.fromChannel(Map<dynamic, dynamic> map) => InstalledApp(
    packageName: map['package'] as String? ?? '',
    appName: map['label'] as String? ?? '',
    icon: map['icon'] as Uint8List?,
  );

  final String packageName;
  final String appName;
  final Uint8List? icon;

  @override
  List<Object?> get props => [packageName, appName, icon];
}
