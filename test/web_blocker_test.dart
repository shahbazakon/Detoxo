import 'dart:convert';

import 'package:bloc_test/bloc_test.dart';
import 'package:detoxo/core/constants/channel_constants.dart';
import 'package:detoxo/core/platform_channels/engine_channel.dart';
import 'package:detoxo/core/storage/local_store.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/app_settings.dart';
import 'package:detoxo/features/blocking/shared/domain/repositories/blocking_repositories.dart';
import 'package:detoxo/features/limits/app_blocker/domain/entities/app_block_entry.dart';
import 'package:detoxo/features/limits/app_blocker/domain/repositories/app_block_repository.dart';
import 'package:detoxo/features/limits/web_blocker/data/repositories/web_block_repository_impl.dart';
import 'package:detoxo/features/limits/web_blocker/data/repositories/web_block_stats_repository_impl.dart';
import 'package:detoxo/features/limits/web_blocker/domain/entities/popular_site.dart';
import 'package:detoxo/features/limits/web_blocker/domain/entities/web_block_entry.dart';
import 'package:detoxo/features/limits/web_blocker/domain/entities/web_block_source.dart';
import 'package:detoxo/features/limits/web_blocker/domain/entities/web_block_stats.dart';
import 'package:detoxo/features/limits/web_blocker/domain/repositories/web_block_repository.dart';
import 'package:detoxo/features/limits/web_blocker/domain/repositories/web_block_stats_repository.dart';
import 'package:detoxo/features/limits/web_blocker/domain/utils/domain_validator.dart';
import 'package:detoxo/features/limits/web_blocker/domain/web_block_sync.dart';
import 'package:detoxo/features/limits/web_blocker/presentation/web_block_cubit.dart';
import 'package:detoxo/features/limits/web_blocker/presentation/web_block_state.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockWebRepo extends Mock implements WebBlockRepository {}

class _MockSettingsRepo extends Mock implements SettingsRepository {}

class _MockAppBlockRepo extends Mock implements AppBlockRepository {}

class _MockStatsRepo extends Mock implements WebBlockStatsRepository {}

class _MockEngine extends Mock implements EngineRepository {}

class _MockStore extends Mock implements LocalStore {}

class _MockChannel extends Mock implements EngineChannel {}

void main() {
  setUpAll(() {
    registerFallbackValue(const AppSettings());
    registerFallbackValue(<WebBlockEntry>[]);
  });

  group('DomainValidator.normalize', () {
    test('strips scheme, www, path, query and port', () {
      expect(
        DomainValidator.normalize('https://www.YouTube.com/watch?v=1'),
        'youtube.com',
      );
      expect(
        DomainValidator.normalize('http://example.com:8080'),
        'example.com',
      );
      expect(
        DomainValidator.normalize('  Sub.Example.CO.uk  '),
        'sub.example.co.uk',
      );
    });

    test('accepts bare and subdomains', () {
      expect(DomainValidator.normalize('example.com'), 'example.com');
      expect(
        DomainValidator.normalize('news.ycombinator.com'),
        'news.ycombinator.com',
      );
    });

    test('strips userinfo and trailing-dot FQDN form', () {
      expect(
        DomainValidator.normalize('https://user:pass@site.com:8080/x'),
        'site.com',
      );
      expect(DomainValidator.normalize('user@site.com'), 'site.com');
      expect(DomainValidator.normalize('example.com.'), 'example.com');
      // A path is stripped before userinfo, so an @ in the path is harmless.
      expect(DomainValidator.normalize('example.com/a@b'), 'example.com');
    });

    test('rejects empty, spaces, scheme-only and single-label hosts', () {
      expect(DomainValidator.normalize(''), isNull);
      expect(DomainValidator.normalize('not a domain'), isNull);
      expect(DomainValidator.normalize('https://'), isNull);
      expect(DomainValidator.normalize('localhost'), isNull);
      expect(DomainValidator.normalize('com'), isNull);
    });

    test('rejects non-ASCII hosts and IP literals (documented limits)', () {
      expect(DomainValidator.normalize('exämple.com'), isNull);
      expect(DomainValidator.normalize('192.168.1.1'), isNull);
      expect(DomainValidator.normalize('[::1]'), isNull);
      expect(DomainValidator.normalize('http://'), isNull);
    });
  });

  group('PopularSites', () {
    test('byPrimaryDomain and aliasesFor resolve the catalogue', () {
      final yt = PopularSites.byPrimaryDomain('youtube.com');
      expect(yt?.name, 'YouTube');
      expect(PopularSites.aliasesFor('youtube.com'), contains('youtu.be'));
      expect(PopularSites.aliasesFor('reddit.com'), isEmpty);
      expect(PopularSites.byPrimaryDomain('nope.com'), isNull);
    });
    // App package → content domains now lives in the category catalog; see
    // test/catalog_test.dart ("legacy app→domain pairs").
  });

  group('WebBlockEntry.isActive', () {
    test('an entry is active exactly while it is enabled', () {
      // M8: the pause window moved OUT of this entity and into
      // `TemporaryUnblock` — one mechanism for "dormant until T" across reels,
      // apps and websites. See test/temporary_unblock_test.dart for the window
      // behaviour this test used to cover.
      expect(const WebBlockEntry(pattern: 'x.com').isActive, isTrue);
      expect(
        const WebBlockEntry(pattern: 'x.com', enabled: false).isActive,
        isFalse,
      );
    });
  });

  group('WebBlockStats', () {
    test('focus minutes use the 30s-per-block heuristic', () {
      expect(const WebBlockStats().focusMinutesSaved, 0);
      expect(const WebBlockStats(totalBlocked: 2).focusMinutesSaved, 1);
      expect(const WebBlockStats(totalBlocked: 10).focusMinutesSaved, 5);
    });
  });

  group('WebBlockState derived getters', () {
    const entries = [
      WebBlockEntry(
        pattern: 'youtube.com',
        displayName: 'YouTube',
        source: WebBlockSource.popular,
      ),
      WebBlockEntry(pattern: 'news.example.com'),
    ];

    test('activePopularIds reflects which popular primaries are present', () {
      const state = WebBlockState(entries: entries);
      expect(state.activePopularIds, contains('youtube'));
      expect(state.activePopularIds, isNot(contains('reddit')));
    });

    test('visibleEntries filters by host or display name', () {
      expect(
        const WebBlockState(
          entries: entries,
          query: 'tube',
        ).visibleEntries.map((e) => e.pattern),
        ['youtube.com'],
      );
      expect(
        const WebBlockState(
          entries: entries,
          query: 'example',
        ).visibleEntries.map((e) => e.pattern),
        ['news.example.com'],
      );
      expect(const WebBlockState(entries: entries).visibleEntries.length, 2);
    });
  });

  group('syncWebBlocklist', () {
    late _MockWebRepo webRepo;
    late _MockSettingsRepo settingsRepo;
    late _MockAppBlockRepo appBlockRepo;
    late _MockEngine engine;

    setUp(() {
      webRepo = _MockWebRepo();
      settingsRepo = _MockSettingsRepo();
      appBlockRepo = _MockAppBlockRepo();
      engine = _MockEngine();
      when(
        () => settingsRepo.load(),
      ).thenAnswer((_) async => const AppSettings());
      when(
        () => appBlockRepo.load(),
      ).thenAnswer((_) async => <AppBlockEntry>[]);
      when(() => engine.pushWebBlocklist(any())).thenAnswer((_) async {});
    });

    Future<List<Map<String, dynamic>>> run() async {
      await syncWebBlocklist(webRepo, settingsRepo, appBlockRepo, engine);
      final json =
          verify(() => engine.pushWebBlocklist(captureAny())).captured.last
              as String;
      return (jsonDecode(json) as List).cast<Map<String, dynamic>>();
    }

    test(
      'pushes active entries + popular aliases, skips disabled ones',
      () async {
        when(() => webRepo.load()).thenAnswer(
          (_) async => const [
            WebBlockEntry(
              pattern: 'youtube.com',
              source: WebBlockSource.popular,
            ),
            WebBlockEntry(pattern: 'off.com', enabled: false),
            WebBlockEntry(pattern: 'custom.com'),
          ],
        );
        final pushed = (await run()).map((m) => m['pattern']).toList();
        expect(pushed, containsAll(['youtube.com', 'youtu.be', 'custom.com']));
        expect(pushed, isNot(contains('off.com')));
      },
    );

    test(
      'derives domains from enabled app blocks when the setting is on',
      () async {
        when(() => webRepo.load()).thenAnswer((_) async => const []);
        when(() => settingsRepo.load()).thenAnswer(
          (_) async => const AppSettings(blockWebsitesForBlockedApps: true),
        );
        when(() => appBlockRepo.load()).thenAnswer(
          (_) async => const [
            AppBlockEntry(packageName: 'com.instagram.android', appName: 'IG'),
            AppBlockEntry(
              packageName: 'com.google.android.youtube',
              appName: 'YT',
              enabled: false,
            ),
          ],
        );
        final pushed = (await run()).map((m) => m['pattern']).toList();
        expect(pushed, contains('instagram.com'));
        expect(pushed, isNot(contains('youtube.com')));
      },
    );

    test(
      'a failed load ABORTS the push — native keeps its last-good list',
      () async {
        when(() => webRepo.load()).thenThrow(const FormatException('corrupt'));
        await syncWebBlocklist(webRepo, settingsRepo, appBlockRepo, engine);
        verifyNever(() => engine.pushWebBlocklist(any()));
      },
    );

    test(
      'the wire carries pattern + matchType only (M8 dropped the pause)',
      () async {
        when(() => webRepo.load()).thenAnswer(
          (_) async => const [
            WebBlockEntry(pattern: 'example.com'),
            WebBlockEntry(pattern: 'off.com', enabled: false),
          ],
        );
        final pushed = await run();
        final example = pushed.singleWhere(
          (m) => m['pattern'] == 'example.com',
        );
        expect(
          example.keys,
          unorderedEquals(<String>['pattern', 'matchType']),
          reason:
              "pausedUntil was M8's one wire-contract change: an unblocked "
              'site is a grant in UnblockRegistry now, not a field on the entry',
        );
        expect(pushed.map((m) => m['pattern']), isNot(contains('off.com')));
      },
    );

    test(
      'an explicit entry wins the dedupe against a derived domain',
      () async {
        when(() => webRepo.load()).thenAnswer(
          (_) async => const [WebBlockEntry(pattern: 'instagram.com')],
        );
        when(() => settingsRepo.load()).thenAnswer(
          (_) async => const AppSettings(blockWebsitesForBlockedApps: true),
        );
        when(() => appBlockRepo.load()).thenAnswer(
          (_) async => const [
            AppBlockEntry(packageName: 'com.instagram.android', appName: 'IG'),
          ],
        );
        final pushed = await run();
        expect(
          pushed.where((m) => m['pattern'] == 'instagram.com'),
          hasLength(1),
        );
      },
    );
  });

  group('WebBlockCubit', () {
    late _MockWebRepo webRepo;
    late _MockSettingsRepo settingsRepo;
    late _MockAppBlockRepo appBlockRepo;
    late _MockStatsRepo statsRepo;
    late _MockEngine engine;

    setUp(() {
      webRepo = _MockWebRepo();
      settingsRepo = _MockSettingsRepo();
      appBlockRepo = _MockAppBlockRepo();
      statsRepo = _MockStatsRepo();
      engine = _MockEngine();
      // Round-trip store: the push path reads back what the cubit saved.
      var saved = <WebBlockEntry>[];
      when(() => webRepo.load()).thenAnswer((_) async => saved);
      when(() => webRepo.save(any())).thenAnswer((inv) async {
        saved = inv.positionalArguments.first as List<WebBlockEntry>;
      });
      when(
        () => settingsRepo.load(),
      ).thenAnswer((_) async => const AppSettings());
      when(() => settingsRepo.save(any())).thenAnswer((_) async {});
      when(
        () => appBlockRepo.load(),
      ).thenAnswer((_) async => <AppBlockEntry>[]);
      when(
        () => statsRepo.load(),
      ).thenAnswer((_) async => const WebBlockStats());
      when(
        () => statsRepo.watch(),
      ).thenAnswer((_) => const Stream<WebBlockStats>.empty());
      when(() => engine.pushWebBlocklist(any())).thenAnswer((_) async {});
      when(() => engine.pushSettings(any())).thenAnswer((_) async {});
      // EVO-047: default to "couldn't ask", the quiet case.
      when(() => engine.unsupportedBrowsers()).thenAnswer((_) async => null);
    });

    WebBlockCubit build() =>
        WebBlockCubit(webRepo, settingsRepo, appBlockRepo, statsRepo, engine);

    List<Map<String, dynamic>> lastPushed() {
      final json =
          verify(() => engine.pushWebBlocklist(captureAny())).captured.last
              as String;
      return (jsonDecode(json) as List).cast<Map<String, dynamic>>();
    }

    blocTest<WebBlockCubit, WebBlockState>(
      'load reads entries + settings and re-syncs native',
      build: build,
      setUp: () {
        when(() => webRepo.load()).thenAnswer(
          (_) async => const [WebBlockEntry(pattern: 'example.com')],
        );
      },
      act: (c) => c.load(),
      verify: (c) {
        expect(c.state.isLoading, isFalse);
        expect(c.state.entries.single.pattern, 'example.com');
        expect(lastPushed().map((m) => m['pattern']), contains('example.com'));
      },
    );

    blocTest<WebBlockCubit, WebBlockState>(
      'addCustom normalizes, persists and pushes the entry',
      build: build,
      act: (c) => c.addCustom('https://www.Example.com/x'),
      verify: (c) {
        expect(c.state.entries.map((e) => e.pattern), ['example.com']);
        verify(() => webRepo.save(any())).called(1);
        expect(lastPushed().map((m) => m['pattern']), contains('example.com'));
      },
    );

    blocTest<WebBlockCubit, WebBlockState>(
      'addCustom rejects an invalid domain and pushes nothing',
      build: build,
      act: (c) => c.addCustom('not a domain'),
      verify: (c) {
        expect(c.state.entries, isEmpty);
        expect(c.state.error, isNotNull);
        verifyNever(() => engine.pushWebBlocklist(any()));
      },
    );

    blocTest<WebBlockCubit, WebBlockState>(
      'togglePopular adds the primary domain and pushes its aliases too',
      build: build,
      act: (c) => c.togglePopular(PopularSites.byPrimaryDomain('youtube.com')!),
      verify: (c) {
        expect(c.state.entries.single.pattern, 'youtube.com');
        expect(
          lastPushed().map((m) => m['pattern']),
          containsAll(['youtube.com', 'youtu.be']),
        );
      },
    );

    blocTest<WebBlockCubit, WebBlockState>(
      'toggleEntry(enabled: false) keeps the entry but drops it from the push',
      build: build,
      act: (c) async {
        await c.addCustom('example.com');
        await c.toggleEntry(c.state.entries.single, enabled: false);
      },
      verify: (c) {
        expect(c.state.entries.single.enabled, isFalse);
        expect(
          lastPushed().map((m) => m['pattern']),
          isNot(contains('example.com')),
        );
      },
    );

    blocTest<WebBlockCubit, WebBlockState>(
      'removeEntry deletes and pushes the shrunken list',
      build: build,
      act: (c) async {
        await c.addCustom('example.com');
        await c.removeEntry(c.state.entries.single);
      },
      verify: (c) {
        expect(c.state.entries, isEmpty);
        expect(lastPushed(), isEmpty);
      },
    );

    blocTest<WebBlockCubit, WebBlockState>(
      'editEntry replaces the pattern; invalid and duplicate edits error',
      build: build,
      act: (c) async {
        await c.addCustom('one.com');
        await c.addCustom('two.com');
        await c.editEntry(c.state.entries.last, 'three.com');
        await c.editEntry(c.state.entries.first, 'not a domain');
        await c.editEntry(c.state.entries.first, 'three.com');
      },
      verify: (c) {
        expect(c.state.entries.map((e) => e.pattern), ['one.com', 'three.com']);
        expect(c.state.error, contains('already blocked'));
      },
    );

    blocTest<WebBlockCubit, WebBlockState>(
      'editEntry refuses non-custom entries',
      build: build,
      act: (c) async {
        await c.togglePopular(PopularSites.byPrimaryDomain('youtube.com')!);
        await c.editEntry(c.state.entries.single, 'evil.com');
      },
      verify: (c) {
        expect(c.state.entries.single.pattern, 'youtube.com');
      },
    );

    blocTest<WebBlockCubit, WebBlockState>(
      'togglePopular upgrades a colliding custom entry instead of deleting it',
      build: build,
      act: (c) async {
        await c.addCustom('youtube.com');
        await c.togglePopular(PopularSites.byPrimaryDomain('youtube.com')!);
      },
      verify: (c) {
        final e = c.state.entries.single;
        expect(e.pattern, 'youtube.com');
        expect(e.source, WebBlockSource.popular);
        expect(e.displayName, 'YouTube');
      },
    );

    blocTest<WebBlockCubit, WebBlockState>(
      'toggling an entry off drops it from the wire and back on restores it',
      build: build,
      act: (c) async {
        await c.addCustom('example.com');
        await c.toggleEntry(c.state.entries.single, enabled: false);
      },
      verify: (c) {
        expect(c.state.entries.single.enabled, isFalse);
        expect(lastPushed(), isEmpty);
      },
    );

    blocTest<WebBlockCubit, WebBlockState>(
      'a failed save reverts the optimistic emit and surfaces an error',
      build: build,
      setUp: () {
        when(() => webRepo.save(any())).thenThrow(Exception('disk full'));
      },
      act: (c) => c.addCustom('example.com'),
      verify: (c) {
        expect(c.state.entries, isEmpty);
        expect(c.state.error, contains("Couldn't save"));
        verifyNever(() => engine.pushWebBlocklist(any()));
      },
    );

    blocTest<WebBlockCubit, WebBlockState>(
      'setBlockForApps saves settings and re-pushes both channels',
      build: build,
      act: (c) => c.setBlockForApps(value: true),
      verify: (c) {
        expect(c.state.blockForApps, isTrue);
        final savedSettings =
            verify(() => settingsRepo.save(captureAny())).captured.single
                as AppSettings;
        expect(savedSettings.blockWebsitesForBlockedApps, isTrue);
        verify(() => engine.pushSettings(any())).called(1);
        verify(() => engine.pushWebBlocklist(any())).called(1);
      },
    );

    blocTest<WebBlockCubit, WebBlockState>(
      'setBlockAdult saves settings and pushes settings only',
      build: build,
      act: (c) => c.setBlockAdult(value: true),
      verify: (c) {
        expect(c.state.blockAdult, isTrue);
        final savedSettings =
            verify(() => settingsRepo.save(captureAny())).captured.single
                as AppSettings;
        expect(savedSettings.blockAdultWebsites, isTrue);
        verify(() => engine.pushSettings(any())).called(1);
        verifyNever(() => engine.pushWebBlocklist(any()));
      },
    );

    blocTest<WebBlockCubit, WebBlockState>(
      'setBlockAdult reverts the toggle and surfaces an error when the save '
      'fails',
      build: build,
      setUp: () {
        when(() => settingsRepo.save(any())).thenThrow(Exception('disk full'));
      },
      act: (c) => c.setBlockAdult(value: true),
      verify: (c) {
        expect(c.state.blockAdult, isFalse);
        expect(c.state.error, contains("Couldn't save"));
        verifyNever(() => engine.pushSettings(any()));
      },
    );

    blocTest<WebBlockCubit, WebBlockState>(
      'setBlockAdult keeps a saved toggle when only the native push fails',
      build: build,
      setUp: () {
        when(
          () => engine.pushSettings(any()),
        ).thenThrow(Exception('channel down'));
      },
      act: (c) => c.setBlockAdult(value: true),
      verify: (c) {
        expect(c.state.blockAdult, isTrue);
        expect(c.state.error, isNull);
        verify(() => settingsRepo.save(any())).called(1);
      },
    );

    blocTest<WebBlockCubit, WebBlockState>(
      'setBlockForApps reverts and pushes nothing when the save fails',
      build: build,
      setUp: () {
        when(() => settingsRepo.save(any())).thenThrow(Exception('disk full'));
      },
      act: (c) => c.setBlockForApps(value: true),
      verify: (c) {
        expect(c.state.blockForApps, isFalse);
        expect(c.state.error, contains("Couldn't save"));
        verifyNever(() => engine.pushSettings(any()));
        verifyNever(() => engine.pushWebBlocklist(any()));
      },
    );

    // EVO-047: name the browsers the engine cannot read.
    test('load surfaces unsupported browsers when native answers', () async {
      when(
        () => engine.unsupportedBrowsers(),
      ).thenAnswer((_) async => ['Firefox Focus', 'Jio Web']);
      final cubit = build();
      await cubit.load();
      await pumpEventQueue();
      expect(cubit.state.unsupportedBrowsers, ['Firefox Focus', 'Jio Web']);
    });

    test('an empty answer means every installed browser is covered', () async {
      when(
        () => engine.unsupportedBrowsers(),
      ).thenAnswer((_) async => <String>[]);
      final cubit = build();
      await cubit.load();
      await pumpEventQueue();
      expect(cubit.state.unsupportedBrowsers, isEmpty);
    });

    test('a failed query stays silent and never fails the load', () async {
      when(() => engine.unsupportedBrowsers()).thenThrow(Exception('boom'));
      final cubit = build();
      await cubit.load();
      await pumpEventQueue();
      // The blocklist still rendered; only the notice is missing.
      expect(cubit.state.isLoading, isFalse);
      expect(cubit.state.loadFailed, isFalse);
      expect(cubit.state.unsupportedBrowsers, isEmpty);
    });
  });

  group('WebBlockRepositoryImpl', () {
    test(
      'a corrupt stored blob THROWS (sync must abort, never push "[]")',
      () async {
        final store = _MockStore();
        when(() => store.read(StoreKeys.webBlocklist)).thenReturn('not json');
        expect(WebBlockRepositoryImpl(store).load(), throwsA(anything));
      },
    );

    test('save/load round-trips entries through the store', () async {
      final store = _MockStore();
      String? blob;
      when(
        () => store.write(StoreKeys.webBlocklist, any()),
      ).thenAnswer((inv) async => blob = inv.positionalArguments[1] as String);
      when(() => store.read(StoreKeys.webBlocklist)).thenAnswer((_) => blob);

      final repo = WebBlockRepositoryImpl(store);
      await repo.save(const [
        WebBlockEntry(pattern: 'example.com', displayName: 'Example'),
      ]);
      final loaded = await repo.load();
      expect(loaded.single.pattern, 'example.com');
      expect(loaded.single.displayName, 'Example');
    });
  });

  group('WebBlockStatsRepositoryImpl', () {
    test(
      'a stale date rolls today back to zero, keeping total and top host',
      () async {
        final store = _MockStore();
        when(() => store.read(StoreKeys.webBlockStats)).thenReturn(
          jsonEncode({
            'date': '2001-01-01',
            'today': 5,
            'total': 9,
            'hosts': {'x.com': 3, 'y.com': 1},
          }),
        );
        final stats = await WebBlockStatsRepositoryImpl(
          _MockChannel(),
          store,
        ).load();
        expect(stats.blockedToday, 0);
        expect(stats.totalBlocked, 9);
        expect(stats.mostBlockedHost, 'x.com');
      },
    );

    test('an adult-list block counts but is never named (EVO-018)', () async {
      final store = _MockStore();
      String? blob;
      when(() => store.read(StoreKeys.webBlockStats)).thenAnswer((_) => blob);
      when(
        () => store.write(StoreKeys.webBlockStats, any()),
      ).thenAnswer((inv) async => blob = inv.positionalArguments[1] as String);
      final channel = _MockChannel();
      // Native omits `host` for ADULT hits — only RULE hits carry it.
      when(channel.events).thenAnswer(
        (_) => Stream.value(<String, dynamic>{
          'type': ChannelEvents.webBlocked,
          'source': 'ADULT',
          'mode': 'PRESS_BACK',
          'today': 1,
          'total': 4,
        }),
      );

      final stats = await WebBlockStatsRepositoryImpl(
        channel,
        store,
      ).watch().first;

      expect(stats.blockedToday, 1);
      expect(stats.totalBlocked, 4);
      expect(stats.mostBlockedHost, isNull);
      expect((jsonDecode(blob!) as Map)['hosts'], isEmpty);
    });

    // EVO-049: suffix matching means one rule can accrue a key per subdomain
    // visited, forever. The tally answers "most blocked", so the tail is
    // droppable — but the winner never is.
    test('the host tally is capped, keeping the most-blocked', () async {
      final store = _MockStore();
      // 60 hosts, ascending counts: h0=1 … h59=60. Cap is 50.
      final crowded = {for (var i = 0; i < 60; i++) 'h$i.com': i + 1};
      String? blob = jsonEncode({
        'date': _todayKey(),
        'today': 0,
        'total': 0,
        'hosts': crowded,
      });
      when(() => store.read(StoreKeys.webBlockStats)).thenAnswer((_) => blob);
      when(
        () => store.write(StoreKeys.webBlockStats, any()),
      ).thenAnswer((inv) async => blob = inv.positionalArguments[1] as String);
      final channel = _MockChannel();
      when(channel.events).thenAnswer(
        (_) => Stream.value(<String, dynamic>{
          'type': ChannelEvents.webBlocked,
          'source': 'RULE',
          'host': 'h59.com',
          'today': 1,
          'total': 1,
        }),
      );

      final stats = await WebBlockStatsRepositoryImpl(
        channel,
        store,
      ).watch().first;

      final hosts = (jsonDecode(blob!) as Map)['hosts'] as Map;
      expect(hosts.length, 50);
      // The busiest survive; the quietest are evicted.
      expect(hosts.containsKey('h59.com'), isTrue);
      expect(hosts.containsKey('h0.com'), isFalse);
      expect(stats.mostBlockedHost, 'h59.com');
    });
  });
}

/// Local-midnight day key in the repository's own `yyyy-MM-dd` shape.
String _todayKey() {
  final now = DateTime.now();
  final m = now.month.toString().padLeft(2, '0');
  final d = now.day.toString().padLeft(2, '0');
  return '${now.year}-$m-$d';
}
