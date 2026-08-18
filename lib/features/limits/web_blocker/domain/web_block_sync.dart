import 'dart:convert';

import 'package:detoxo/core/utils/app_logger.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
import 'package:detoxo/features/blocking/shared/domain/repositories/blocking_repositories.dart';
import 'package:detoxo/features/limits/app_blocker/domain/repositories/app_block_repository.dart';
import 'package:detoxo/features/limits/web_blocker/domain/entities/app_domain_catalog.dart';
import 'package:detoxo/features/limits/web_blocker/domain/entities/popular_site.dart';
import 'package:detoxo/features/limits/web_blocker/domain/entities/web_block_source.dart';
import 'package:detoxo/features/limits/web_blocker/domain/repositories/web_block_repository.dart';

/// Builds the merged, deduped active web blocklist from persisted state and
/// ships it to the native engine: every active entry, the aliases of any
/// popular entry, and — when `blockWebsitesForBlockedApps` is on — the domains
/// derived from the enabled App Blocker entries via [AppDomainCatalog].
///
/// The single push path, called from the Web Blocker cubit, the splash
/// bootstrap (repairs Dart→native drift, e.g. after "Reset app data"), and
/// App Blocker mutations (so derived domains never go stale).
Future<void> syncWebBlocklist(
  WebBlockRepository repo,
  SettingsRepository settings,
  AppBlockRepository appBlocks,
  EngineRepository engine,
) async {
  // Best-effort by contract: a failed load ABORTS the push (native keeps
  // enforcing its last-good persisted list — the fail-safe direction) and is
  // reported non-fatally. Never let a corrupt Dart store push "[]" and wipe
  // native, and never let a background sync book a fatal into Crashlytics.
  try {
    await _push(repo, settings, appBlocks, engine);
  } on Object catch (e, s) {
    AppLogger.e('web blocklist sync failed', e, s);
  }
}

Future<void> _push(
  WebBlockRepository repo,
  SettingsRepository settings,
  AppBlockRepository appBlocks,
  EngineRepository engine,
) async {
  final entries = await repo.load();
  final now = DateTime.now();
  final patterns = <String, Map<String, Object>>{}; // pattern -> wire map
  for (final e in entries) {
    if (!e.enabled) continue;
    // Paused entries stay in the wire with their expiry: native enforces the
    // window and re-arms at expiry even if this app is never reopened.
    patterns[e.pattern] = {
      'pattern': e.pattern,
      'matchType': e.matchType.wire,
      if (e.isPausedAt(now))
        'pausedUntil': e.pausedUntil!.millisecondsSinceEpoch,
    };
    if (e.source == WebBlockSource.popular) {
      for (final alias in PopularSites.aliasesFor(e.pattern)) {
        patterns.putIfAbsent(
          alias,
          () => {
            'pattern': alias,
            'matchType': WebMatchType.domain.wire,
            if (e.isPausedAt(now))
              'pausedUntil': e.pausedUntil!.millisecondsSinceEpoch,
          },
        );
      }
    }
  }
  if ((await settings.load()).blockWebsitesForBlockedApps) {
    final apps = await appBlocks.load();
    for (final app in apps) {
      if (!app.enabled) continue;
      for (final domain in AppDomainCatalog.domainsFor(app.packageName)) {
        patterns.putIfAbsent(
          domain,
          () => {'pattern': domain, 'matchType': WebMatchType.domain.wire},
        );
      }
    }
  }
  await engine.pushWebBlocklist(jsonEncode(patterns.values.toList()));
}
