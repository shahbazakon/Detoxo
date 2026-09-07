import 'dart:async';

import 'package:detoxo/core/platform_channels/engine_channel.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/block_target.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
import 'package:detoxo/features/blocking/shared/domain/repositories/blocking_repositories.dart';
import 'package:detoxo/features/content_counter/content_counter.dart';
import 'package:detoxo/features/content_counter/content_counter_core/data/repositories/content_counter_repository_impl.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockChannel extends Mock implements EngineChannel {}

class _MockConfig extends Mock implements ConfigRepository {}

class _MockCounterRepo extends Mock implements ContentCounterRepository {}

class _MockBubble extends Mock implements BubbleRepository {}

class _MockAppearanceRepo extends Mock implements CounterAppearanceRepository {}

BlockTarget _target(String pkg, String name) => BlockTarget(
  platformId: '${name}_reels',
  packageName: pkg,
  appName: name,
  displayName: '$name Reels',
  iconUrl: 'https://cdn.example/$name.png',
  detectionType: DetectionType.legacy,
  premiumExclusive: false,
  defaultEnabled: true,
  isBrowser: false,
);

/// Pins the native-snapshot → domain mapping (`_fromMap` / `_toList`) and the
/// cubit's stream handling — the rule that once corrupted the toggles was a
/// missing flag defaulting to true.
void main() {
  setUpAll(() {
    registerFallbackValue(const ContentCount.empty());
    registerFallbackValue(const BubbleStyle.defaults());
  });

  group('ContentCounterRepositoryImpl', () {
    late _MockChannel channel;
    late _MockConfig config;
    late ContentCounterRepositoryImpl repo;

    setUp(() {
      channel = _MockChannel();
      config = _MockConfig();
      repo = ContentCounterRepositoryImpl(channel, config);
      when(() => config.loadBlockTargets()).thenAnswer(
        (_) async => [_target('com.instagram.android', 'Instagram')],
      );
    });

    test(
      'maps a full snapshot; per-app lists sorted desc, zero rows dropped',
      () async {
        when(() => channel.contentCounterSnapshot()).thenAnswer(
          (_) async => {
            'today': 7,
            'total': 120,
            'enabled': false,
            'bubbleEnabled': false,
            'timeTodayMs': 90000,
            'perAppToday': {
              'com.instagram.android': 2,
              'com.google.android.youtube': 5,
              'com.zhiliaoapp.musically': 0,
            },
            'perAppTotal': {'com.instagram.android': 120},
          },
        );

        final c = await repo.current();

        expect(c.today, 7);
        expect(c.total, 120);
        expect(c.enabled, false);
        expect(c.bubbleEnabled, false);
        expect(c.timeToday, const Duration(seconds: 90));
        expect(c.perAppToday.map((a) => a.packageName), [
          'com.google.android.youtube',
          'com.instagram.android',
        ]);
        // Catalogued app → catalog name + icon; unknown app → bare package.
        expect(c.perAppToday[1].displayName, 'Instagram Reels');
        expect(c.perAppToday[1].iconUrl, isNotEmpty);
        expect(c.perAppToday[0].appName, 'com.google.android.youtube');
        expect(c.perAppToday[0].iconUrl, isEmpty);
      },
    );

    test(
      'missing flags default to ON; non-map breakdowns read as empty',
      () async {
        when(
          () => channel.contentCounterSnapshot(),
        ).thenAnswer((_) async => {'today': 1, 'perAppToday': 'garbage'});

        final c = await repo.current();

        expect(c.enabled, true);
        expect(c.bubbleEnabled, true);
        expect(c.perAppToday, isEmpty);
        expect(c.perAppTotal, isEmpty);
        expect(c.timeToday, Duration.zero);
      },
    );

    test('only the pre-pull placeholder is unloaded', () async {
      // The dashboard streak gate keys on this: a placeholder `enabled: true`
      // must never be mistaken for a reading that counting is on.
      expect(const ContentCount.empty().loaded, false);
      expect(const ContentCount.empty().copyWith(enabled: false).loaded, false);
      when(
        () => channel.contentCounterSnapshot(),
      ).thenAnswer((_) async => {'enabled': false});

      final c = await repo.current();

      expect(c.loaded, true);
      expect(c.enabled, false);
    });

    test(
      'a catalog failure degrades to package names, not a dead counter',
      () async {
        when(
          () => config.loadBlockTargets(),
        ).thenThrow(StateError('bad asset'));
        when(() => channel.contentCounterSnapshot()).thenAnswer(
          (_) async => {
            'today': 3,
            'perAppToday': {'com.instagram.android': 3},
          },
        );

        final c = await repo.current();

        expect(c.today, 3);
        expect(c.perAppToday.single.displayName, 'com.instagram.android');
      },
    );

    test(
      'watch() yields the snapshot, then only contentCounted events',
      () async {
        when(
          () => channel.contentCounterSnapshot(),
        ).thenAnswer((_) async => {'today': 1});
        when(() => channel.events()).thenAnswer(
          (_) => Stream.fromIterable([
            {'type': 'blocked', 'today': 99},
            {'type': 'contentCounted', 'today': 2, 'enabled': true},
          ]),
        );

        final counts = await repo.watch().map((c) => c.today).toList();

        expect(counts, [1, 2]);
      },
    );

    test('watch() skips a malformed event instead of ending', () async {
      when(
        () => channel.contentCounterSnapshot(),
      ).thenAnswer((_) async => {'today': 1});
      when(() => channel.events()).thenAnswer(
        (_) => Stream.fromIterable([
          {'type': 'contentCounted', 'today': 'not a number'},
          {'type': 'contentCounted', 'today': 2},
        ]),
      );

      // A throw inside the async* body would end the stream after [1].
      final counts = await repo.watch().map((c) => c.today).toList();

      expect(counts, [1, 2]);
    });
  });

  group('ContentCounterCubit', () {
    late _MockCounterRepo repo;
    late _MockBubble bubble;
    late StreamController<ContentCount> stream;

    setUp(() {
      repo = _MockCounterRepo();
      bubble = _MockBubble();
      stream = StreamController<ContentCount>();
      when(() => repo.watch()).thenAnswer((_) => stream.stream);
      when(
        () => repo.setEnabled(enabled: any(named: 'enabled')),
      ).thenAnswer((_) async {});
      when(
        () => bubble.setEnabled(enabled: any(named: 'enabled')),
      ).thenAnswer((_) async {});
      when(() => bubble.requestPermission()).thenAnswer((_) async {});
      when(() => bubble.canShow()).thenAnswer((_) async => true);
    });

    tearDown(() => stream.close());

    test(
      'streamed counts keep the overlay state; a stream error is survived',
      () async {
        final cubit = ContentCounterCubit(repo, bubble);
        await Future<void>.delayed(Duration.zero); // overlay read lands
        expect(cubit.state.overlayGranted, true);

        stream
          ..addError(StateError('bad payload'))
          ..add(const ContentCount(today: 4));
        await Future<void>.delayed(Duration.zero);

        expect(cubit.state.today, 4);
        expect(cubit.state.overlayGranted, true);
        await cubit.close();
      },
    );

    test(
      'turning the bubble on without the grant opens the system screen',
      () async {
        when(() => bubble.canShow()).thenAnswer((_) async => false);
        final cubit = ContentCounterCubit(repo, bubble);

        await cubit.setBubbleEnabled(enabled: true);

        expect(cubit.state.bubbleEnabled, true);
        expect(cubit.state.overlayGranted, false);
        expect(cubit.state.bubbleBlocked, true);
        verify(() => bubble.requestPermission()).called(1);
        await cubit.close();
      },
    );

    test('an unanswered overlay read is unknown, never blocked', () async {
      when(() => bubble.canShow()).thenAnswer((_) async => null);
      final cubit = ContentCounterCubit(repo, bubble);

      await cubit.setBubbleEnabled(enabled: true);

      expect(cubit.state.overlayGranted, isNull);
      expect(cubit.state.bubbleBlocked, false);
      verifyNever(() => bubble.requestPermission());
      await cubit.close();
    });

    test('setEnabled is optimistic and pushes native', () async {
      final cubit = ContentCounterCubit(repo, bubble);

      await cubit.setEnabled(enabled: false);

      expect(cubit.state.enabled, false);
      verify(() => repo.setEnabled(enabled: false)).called(1);
      await cubit.close();
    });
  });

  group('CounterAppearanceCubit', () {
    test(
      'an edit that beats the hydrate wins; the other surface still loads',
      () async {
        final repo = _MockAppearanceRepo();
        final hydrate = Completer<CounterAppearance>();
        when(repo.current).thenAnswer((_) => hydrate.future);
        when(() => repo.setBubbleStyle(any())).thenAnswer((_) async {});
        final cubit = CounterAppearanceCubit(repo);
        final edited = const BubbleStyle.defaults().copyWith(size: 60);

        cubit.setBubble(edited);
        hydrate.complete(
          CounterAppearance(
            bubble: const BubbleStyle.defaults().copyWith(size: 44),
            widget: const WidgetStyle.defaults().copyWith(showLabel: false),
          ),
        );
        await Future<void>.delayed(Duration.zero);

        expect(cubit.state.bubble, edited); // not snapped back to 44
        expect(
          cubit.state.widget.showLabel,
          false,
        ); // untouched surface hydrated
        await cubit.close();
      },
    );
  });

  group('formatBubbleClock (mirror of native BubbleView.formatMs)', () {
    test('seconds / m:ss / h:mm:ss', () {
      expect(formatBubbleClock(const Duration(seconds: 45)), '45s');
      expect(formatBubbleClock(const Duration(minutes: 3, seconds: 5)), '3:05');
      expect(
        formatBubbleClock(const Duration(hours: 1, minutes: 23, seconds: 45)),
        '1:23:45',
      );
      expect(formatBubbleClock(Duration.zero), '0s');
    });
  });
}
