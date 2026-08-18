import 'dart:convert';

import 'package:detoxo/core/constants/channel_constants.dart';
import 'package:detoxo/core/platform_channels/engine_channel.dart';
import 'package:detoxo/core/storage/local_store.dart';
import 'package:detoxo/features/limits/web_blocker/domain/entities/web_block_stats.dart';
import 'package:detoxo/features/limits/web_blocker/domain/repositories/web_block_stats_repository.dart';

/// Persists website-block analytics to [LocalStore] and keeps them live off the
/// native `webBlocked` event stream.
///
/// The native engine is the source of truth for the running today/total counts
/// (it survives the UI being killed); we mirror them here and additionally keep
/// a per-host tally so the dashboard can surface the most-blocked website. The
/// `today` count rolls over on a new calendar day.
class WebBlockStatsRepositoryImpl implements WebBlockStatsRepository {
  WebBlockStatsRepositoryImpl(this._channel, this._store);

  final EngineChannel _channel;
  final LocalStore _store;

  @override
  Future<WebBlockStats> load() async {
    final data = _read();
    _rollDate(data);
    return _toStats(data);
  }

  @override
  Stream<WebBlockStats> watch() async* {
    await for (final e in _channel.events()) {
      if (e['type'] != ChannelEvents.webBlocked) continue;
      final data = _read();
      _rollDate(data);

      final host = (e['host'] as String?)?.trim();
      if (host != null && host.isNotEmpty) {
        final hosts = Map<String, dynamic>.from(data['hosts'] as Map);
        hosts[host] = ((hosts[host] as int?) ?? 0) + 1;
        data['hosts'] = hosts;
      }

      // Prefer the engine-supplied counters; fall back to incrementing locally
      // if the payload omitted them.
      data['today'] = e['today'] as int? ?? ((data['today'] as int? ?? 0) + 1);
      data['total'] = e['total'] as int? ?? ((data['total'] as int? ?? 0) + 1);

      await _store.write(StoreKeys.webBlockStats, jsonEncode(data));
      yield _toStats(data);
    }
  }

  Map<String, dynamic> _read() {
    final raw = _store.read(StoreKeys.webBlockStats);
    if (raw != null) {
      // A corrupt stats blob must not kill the live watch() stream — fall back
      // to a fresh day (stats are advisory; the native counters self-heal it).
      try {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        map['hosts'] ??= <String, dynamic>{};
        return map;
      } on Object {
        // fall through to the fresh blob
      }
    }
    return {
      'date': _todayKey(),
      'today': 0,
      'total': 0,
      'hosts': <String, dynamic>{},
    };
  }

  /// Resets the day counter when the stored date is no longer today.
  void _rollDate(Map<String, dynamic> data) {
    final today = _todayKey();
    if (data['date'] != today) {
      data['date'] = today;
      data['today'] = 0;
    }
  }

  WebBlockStats _toStats(Map<String, dynamic> data) {
    final hosts = (data['hosts'] as Map?)?.cast<String, dynamic>() ?? const {};
    String? top;
    var topCount = 0;
    hosts.forEach((host, count) {
      final c = (count as int?) ?? 0;
      if (c > topCount) {
        topCount = c;
        top = host;
      }
    });
    return WebBlockStats(
      totalBlocked: data['total'] as int? ?? 0,
      blockedToday: data['today'] as int? ?? 0,
      mostBlockedHost: top,
    );
  }

  String _todayKey() {
    final now = DateTime.now();
    final m = now.month.toString().padLeft(2, '0');
    final d = now.day.toString().padLeft(2, '0');
    return '${now.year}-$m-$d';
  }
}
