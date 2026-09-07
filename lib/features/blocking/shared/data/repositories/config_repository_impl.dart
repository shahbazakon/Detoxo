import 'dart:convert';

import 'package:detoxo/core/constants/app_constants.dart';
import 'package:detoxo/features/blocking/shared/data/models/initial_config_model.dart';
import 'package:detoxo/features/blocking/shared/data/models/platform_config_model.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/app_notice.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/block_target.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
import 'package:detoxo/features/blocking/shared/domain/repositories/blocking_repositories.dart';
import 'package:flutter/services.dart';

/// Offline-first config: reads the bundled JSON assets. A remote refresh can be
/// layered in later behind the same interface (see networking doc) — the rest of
/// the app is unaffected.
class ConfigRepositoryImpl implements ConfigRepository {
  ConfigRepositoryImpl({AssetBundle? bundle}) : _bundle = bundle ?? rootBundle;

  final AssetBundle _bundle;
  String? _cachedRaw;
  PlatformConfigModel? _cachedConfig;

  Future<PlatformConfigModel> _config() async {
    if (_cachedConfig != null) return _cachedConfig!;
    final raw = await rawConfigJson();
    final map = jsonDecode(raw) as Map<String, dynamic>;
    return _cachedConfig = PlatformConfigModel.fromJson(map);
  }

  @override
  Future<String> rawConfigJson() async => _cachedRaw ??= await _bundle
      .loadString(AppConstants.bundledPlatformsConfig);

  @override
  Future<List<BlockTarget>> loadBlockTargets({
    Set<String>? installedPackages,
  }) async {
    final config = await _config();
    final targets = <BlockTarget>[];
    for (final app in config.featuredApps.values) {
      for (final platform in app.platforms) {
        if (!platform.showInDashboard && !platform.showAlwaysInBlockList) {
          continue;
        }
        final packageName = platform.packageName.isNotEmpty
            ? platform.packageName
            : app.packageName;
        // Unknown install state (null) => treat as installed and show all.
        final isInstalled =
            installedPackages == null ||
            installedPackages.contains(packageName);
        // Hide uninstalled apps unless flagged as a suggestion to surface.
        if (!isInstalled && !app.showIfNotInstalled) continue;
        targets.add(_toTarget(app, platform, isInstalled: isInstalled));
      }
    }
    // Installed apps first, then alphabetically by app name.
    targets.sort((a, b) {
      if (a.isInstalled != b.isInstalled) return a.isInstalled ? -1 : 1;
      return a.appName.compareTo(b.appName);
    });
    return targets;
  }

  BlockTarget _toTarget(
    AppDetailsModel app,
    PlatformModel platform, {
    required bool isInstalled,
  }) {
    // The detectors' supportedBlockModes are consumed natively
    // (resolveBlockMode); Dart never read them, so they are not surfaced.
    return BlockTarget(
      platformId: platform.platformId,
      packageName: platform.packageName.isNotEmpty
          ? platform.packageName
          : app.packageName,
      appName: app.appName,
      displayName: platform.platformName.isNotEmpty
          ? platform.platformName
          : app.appName,
      iconUrl: platform.iconUrl.isNotEmpty ? platform.iconUrl : app.iconUrl,
      detectionType: DetectionType.fromWire(platform.detectionType),
      premiumExclusive: platform.premiumExclusive,
      defaultEnabled: platform.defaultStatus,
      isBrowser: app.isBrowser,
      isInstalled: isInstalled,
    );
  }

  @override
  Future<List<AppNotice>> loadNotices() async {
    try {
      final raw = await _bundle.loadString(AppConstants.bundledInitialConfig);
      final model = InitialConfigModel.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
      return model.inappNotification
          .map(
            (n) => AppNotice(
              id: n.notificationId,
              title: n.title,
              description: n.description,
              cta: n.cta,
              action: n.ctaAction,
              url: n.ctaUrl,
              dismissible: n.dismissible,
            ),
          )
          .toList();
    } on Exception {
      return const [];
    }
  }
}
