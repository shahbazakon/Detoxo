import 'package:detoxo/core/constants/channel_constants.dart';
import 'package:detoxo/core/platform_channels/engine_channel.dart';
import 'package:detoxo/core/utils/app_logger.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/block_target.dart';
import 'package:detoxo/features/blocking/shared/domain/repositories/blocking_repositories.dart';
import 'package:detoxo/features/content_counter/content_counter_core/domain/entities/app_content_count.dart';
import 'package:detoxo/features/content_counter/content_counter_core/domain/entities/content_count.dart';
import 'package:detoxo/features/content_counter/content_counter_core/domain/repositories/content_counter_repository.dart';

/// Bridges the native counter to the domain: pulls/streams snapshots and
/// enriches each per-app entry with its catalog name + icon via [ConfigRepository].
class ContentCounterRepositoryImpl implements ContentCounterRepository {
  ContentCounterRepositoryImpl(this._channel, this._config);

  final EngineChannel _channel;
  final ConfigRepository _config;

  /// package -> catalog metadata, built once (name/icon for the breakdown).
  Map<String, BlockTarget>? _appIndex;

  Future<Map<String, BlockTarget>> _index() async {
    final cached = _appIndex;
    if (cached != null) return cached;
    final index = <String, BlockTarget>{};
    // The catalog only decorates the breakdown (names + icons). A catalog
    // failure must not take the counter with it — fall back to bare package
    // names and retry the catalog on the next read.
    try {
      for (final t in await _config.loadBlockTargets()) {
        index.putIfAbsent(t.packageName, () => t);
      }
    } on Object catch (e) {
      AppLogger.e('counter app index', e);
      return index;
    }
    return _appIndex = index;
  }

  @override
  Future<ContentCount> current() async =>
      _fromMap(await _channel.contentCounterSnapshot(), await _index());

  @override
  Stream<ContentCount> watch() async* {
    final index = await _index();
    yield _fromMap(await _channel.contentCounterSnapshot(), index);
    await for (final e in _channel.events()) {
      if (e['type'] != ChannelEvents.contentCounted) continue;
      // A throw inside an async* body ends the generator for good, so one
      // malformed event (a trust-boundary payload) must be skipped, not
      // propagated — else the live count freezes for the session.
      final ContentCount next;
      try {
        next = _fromMap(e, index);
      } on Object catch (error) {
        AppLogger.e('contentCounted payload', error);
        continue;
      }
      yield next;
    }
  }

  @override
  Future<void> setEnabled({required bool enabled}) =>
      _channel.setContentCounterEnabled(enabled: enabled);

  ContentCount _fromMap(
    Map<String, dynamic> map,
    Map<String, BlockTarget> index,
  ) {
    return ContentCount(
      today: (map['today'] as num?)?.toInt() ?? 0,
      total: (map['total'] as num?)?.toInt() ?? 0,
      enabled: map['enabled'] as bool? ?? true,
      bubbleEnabled: map['bubbleEnabled'] as bool? ?? true,
      perAppToday: _toList(map['perAppToday'], index),
      perAppTotal: _toList(map['perAppTotal'], index),
      timeToday: Duration(
        milliseconds: (map['timeTodayMs'] as num?)?.toInt() ?? 0,
      ),
    );
  }

  List<AppContentCount> _toList(dynamic raw, Map<String, BlockTarget> index) {
    if (raw is! Map) return const [];
    final out = <AppContentCount>[];
    raw.forEach((key, value) {
      final pkg = key.toString();
      final count = (value as num?)?.toInt() ?? 0;
      if (count <= 0) return;
      final target = index[pkg];
      out.add(
        AppContentCount(
          packageName: pkg,
          appName: target?.appName ?? pkg,
          displayName: target?.displayName ?? target?.appName ?? pkg,
          iconUrl: target?.iconUrl ?? '',
          count: count,
        ),
      );
    });
    out.sort((a, b) => b.count.compareTo(a.count));
    return out;
  }
}
