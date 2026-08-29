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

      data['hosts'] = _trimHosts(data['hosts'] as Map<String, dynamic>);
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
        // `hosts` is re-typed HERE, not at the use site: watch() reads this
        // inside an `await for`, so a bad cast downstream would end the stats
        // stream for the rest of the session instead of failing recoverably.
        map['hosts'] = _sanitiseHosts(map['hosts']);
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

  /// Coerces a stored `hosts` value into a `{host: count}` map, dropping any
  /// pair that is not a host string against a positive int. A blob whose
  /// `hosts` is a scalar, a list or a map of doubles reads back as an empty
  /// tally rather than throwing.
  static Map<String, dynamic> _sanitiseHosts(Object? raw) {
    if (raw is! Map) return <String, dynamic>{};
    final out = <String, dynamic>{};
    raw.forEach((key, value) {
      if (key is String && key.isNotEmpty && value is int && value > 0) {
        out[key] = value;
      }
    });
    return out;
  }

  /// EVO-049: how many hosts the tally keeps. Matching is suffix-based and
  /// native reports the OBSERVED host, so one `google.com` rule would otherwise
  /// accrue a key per subdomain visited, forever — an unbounded browsing
  /// residue, re-encoded on every block. The tally exists to answer "most
  /// blocked"; the tail below the cap cannot be the answer.
  static const _maxTrackedHosts = 50;

  /// Keeps the [_maxTrackedHosts] highest counts, dropping the rest.
  static Map<String, dynamic> _trimHosts(Map<String, dynamic> hosts) {
    if (hosts.length <= _maxTrackedHosts) return hosts;
    final ranked = hosts.entries.toList()
      ..sort(
        (a, b) => ((b.value as int?) ?? 0).compareTo((a.value as int?) ?? 0),
      );
    return {for (final e in ranked.take(_maxTrackedHosts)) e.key: e.value};
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
