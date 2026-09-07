import 'dart:convert';

import 'package:bloc_test/bloc_test.dart';
import 'package:detoxo/features/blocking/blocklist/presentation/targets_cubit.dart';
import 'package:detoxo/features/blocking/blocklist/presentation/widgets/block_app_tile.dart';
import 'package:detoxo/features/blocking/shared/data/repositories/config_repository_impl.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/block_target.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
import 'package:detoxo/features/blocking/shared/domain/repositories/blocking_repositories.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockBundle extends Mock implements AssetBundle {}

class _MockConfigRepository extends Mock implements ConfigRepository {}

class _MockEngineRepository extends Mock implements EngineRepository {}

/// A minimal app entry for the test catalog. Only the fields the install-aware
/// filter reads are set; the model defaults cover the rest.
Map<String, dynamic> _app(
  String pkg,
  String name, {
  required bool showIfNotInstalled,
}) => {
  'packageName': pkg,
  'appName': name,
  'iconUrl': '',
  'showInDashboard': true,
  'showIfNotInstalled': showIfNotInstalled,
  'browser': false,
  'platforms': [
    {
      'platformId': '${pkg}_p',
      'packageName': pkg,
      'platformName': name,
      'iconUrl': '',
      'detectors': <String, dynamic>{},
      'detectionType': 'LEGACY',
      'defaultStatus': true,
      'showInDashboard': true,
      'showAlwaysInBlockList': false,
      'premiumExclusive': false,
    },
  ],
};

// Insertion order (bravo before alpha) is deliberate so the test proves the
// installed-first / alphabetical sort actually reorders the catalog.
final String _catalogJson = jsonEncode({
  'responsecode': 200,
  'featuredApps': {
    'com.app.bravo': _app('com.app.bravo', 'Bravo', showIfNotInstalled: false),
    'com.app.alpha': _app('com.app.alpha', 'Alpha', showIfNotInstalled: false),
    'com.app.suggested': _app(
      'com.app.suggested',
      'Suggested',
      showIfNotInstalled: true,
    ),
    'com.app.hidden': _app(
      'com.app.hidden',
      'Hidden',
      showIfNotInstalled: false,
    ),
  },
});

void main() {
  group('ConfigRepositoryImpl.loadBlockTargets (install-aware)', () {
    late _MockBundle bundle;
    late ConfigRepositoryImpl repo;

    setUp(() {
      bundle = _MockBundle();
      when(
        () => bundle.loadString(any()),
      ).thenAnswer((_) async => _catalogJson);
      repo = ConfigRepositoryImpl(bundle: bundle);
    });

    test('drops uninstalled non-suggestions, keeps suggestions greyed, sorts '
        'installed-first then alphabetically', () async {
      final targets = await repo.loadBlockTargets(
        installedPackages: {'com.app.bravo', 'com.app.alpha'},
      );

      // Hidden (uninstalled + showIfNotInstalled:false) is gone; the rest sorted
      // installed-first (Alpha, Bravo) then the greyed suggestion.
      expect(targets.map((t) => t.displayName), [
        'Alpha',
        'Bravo',
        'Suggested',
      ]);
      expect(
        {for (final t in targets) t.displayName: t.isInstalled},
        {'Alpha': true, 'Bravo': true, 'Suggested': false},
      );
    });

    test(
      'null installed set => show everything as installed (off-Android)',
      () async {
        final targets = await repo.loadBlockTargets();

        expect(targets.map((t) => t.displayName), [
          'Alpha',
          'Bravo',
          'Hidden',
          'Suggested',
        ]);
        expect(targets.every((t) => t.isInstalled), isTrue);
      },
    );

    test('empty installed set hides every non-suggested app', () async {
      final targets = await repo.loadBlockTargets(installedPackages: const {});

      expect(targets.map((t) => t.displayName), ['Suggested']);
      expect(targets.single.isInstalled, isFalse);
    });
  });

  group('TargetsCubit.load()', () {
    late _MockConfigRepository config;
    late _MockEngineRepository engine;

    const target = BlockTarget(
      platformId: 'p',
      packageName: 'com.x',
      appName: 'X',
      displayName: 'X',
      iconUrl: '',
      detectionType: DetectionType.legacy,
      premiumExclusive: false,
      defaultEnabled: true,
      isBrowser: false,
    );

    setUp(() {
      config = _MockConfigRepository();
      engine = _MockEngineRepository();
      when(() => config.rawConfigJson()).thenAnswer((_) async => '{}');
      when(() => engine.pushConfig(any())).thenAnswer((_) async {});
      when(() => engine.installedPackages()).thenAnswer((_) async => {'com.x'});
      when(
        () => config.loadBlockTargets(
          installedPackages: any(named: 'installedPackages'),
        ),
      ).thenAnswer((_) async => [target]);
    });

    blocTest<TargetsCubit, TargetsState>(
      'passes the engine-reported installed set into loadBlockTargets',
      build: () => TargetsCubit(config, engine),
      act: (cubit) => cubit.load(),
      expect: () => const [
        TargetsState(isLoading: true),
        TargetsState(targets: [target]),
      ],
      verify: (_) {
        final captured = verify(
          () => config.loadBlockTargets(
            installedPackages: captureAny(named: 'installedPackages'),
          ),
        ).captured.single;
        expect(captured, {'com.x'});
      },
    );
  });

  group('BlockAppGroup.from', () {
    BlockTarget surface(
      String pkg,
      String app,
      String platformId, {
      bool installed = true,
    }) => BlockTarget(
      platformId: platformId,
      packageName: pkg,
      appName: app,
      displayName: platformId,
      iconUrl: '',
      detectionType: DetectionType.legacy,
      premiumExclusive: false,
      defaultEnabled: true,
      isBrowser: false,
      isInstalled: installed,
    );

    test(
      'collapses surfaces sharing a package into one group, preserving order',
      () {
        final groups = BlockAppGroup.from([
          surface('com.insta', 'Instagram', 'ig_feed'),
          surface('com.insta', 'Instagram', 'ig_reel'),
          surface('com.yt', 'YouTube', 'yt_shorts'),
        ]);

        expect(groups.map((g) => g.appName), ['Instagram', 'YouTube']);
        expect(groups.first.surfaces.map((t) => t.platformId), [
          'ig_feed',
          'ig_reel',
        ]);
        expect(groups.first.isSingle, isFalse);
        expect(groups.last.isSingle, isTrue);
      },
    );

    test('derives install state from the grouped surfaces', () {
      final groups = BlockAppGroup.from([
        surface('com.tt', 'TikTok', 'tt_feed', installed: false),
      ]);

      expect(groups.single.isInstalled, isFalse);
      expect(groups.single.isSingle, isTrue);
    });
  });
}
