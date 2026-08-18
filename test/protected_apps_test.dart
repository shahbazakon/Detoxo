import 'dart:convert';

import 'package:bloc_test/bloc_test.dart';
import 'package:detoxo/core/storage/local_store.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/block_target.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
import 'package:detoxo/features/blocking/shared/domain/repositories/blocking_repositories.dart';
import 'package:detoxo/features/protected_apps/data/repositories/protected_apps_repository_impl.dart';
import 'package:detoxo/features/protected_apps/domain/entities/protected_app.dart';
import 'package:detoxo/features/protected_apps/domain/entities/protected_app_catalog.dart';
import 'package:detoxo/features/protected_apps/domain/protected_apps_boot.dart';
import 'package:detoxo/features/protected_apps/presentation/protected_apps_cubit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockEngine extends Mock implements EngineRepository {}

class _MockConfig extends Mock implements ConfigRepository {}

/// In-memory [LocalStore] (no Hive / secure storage) for repository tests.
class _FakeStore implements LocalStore {
  final Map<String, String> plain = {};

  @override
  String? read(String key) => plain[key];
  @override
  Future<void> write(String key, String value) async => plain[key] = value;
  @override
  Future<void> delete(String key) async => plain.remove(key);
  @override
  Future<String?> readSecret(String key) async => null;
  @override
  Future<void> writeSecret(String key, String value) async {}
  @override
  Future<void> deleteSecret(String key) async {}
  @override
  Future<void> clearAll() async => plain.clear();
}

BlockTarget _target(String pkg) => BlockTarget(
  platformId: '${pkg}_reel',
  packageName: pkg,
  appName: pkg,
  displayName: pkg,
  iconUrl: '',
  detectionType: DetectionType.legacy,
  supportedModes: const [],
  premiumExclusive: false,
  defaultEnabled: true,
  isBrowser: false,
);

final List<String> _catalogPackages = [
  for (final a in ProtectedAppCatalog.apps) a.packageName,
];

void main() {
  group('ProtectedApp serialization', () {
    test('defaults: enabled manual entry in the Other category', () {
      const app = ProtectedApp(packageName: 'com.x', appName: 'X');
      expect(app.category, ProtectedAppCategory.other);
      expect(app.isEnabled, isTrue);
      expect(app.source, ProtectedAppSource.manual);
    });

    test('toJson writes the wire tokens', () {
      const app = ProtectedApp(
        packageName: 'com.x8bit.bitwarden',
        appName: 'Bitwarden',
        category: ProtectedAppCategory.passwordManager,
        source: ProtectedAppSource.catalog,
      );
      expect(app.toJson(), {
        'packageName': 'com.x8bit.bitwarden',
        'appName': 'Bitwarden',
        'category': 'password_manager',
        'isEnabled': true,
        'source': 'catalog',
      });
    });

    test('fromJson tolerates missing and unknown keys', () {
      final sparse = ProtectedApp.fromJson(const {'packageName': 'com.x'});
      expect(sparse.appName, '');
      expect(sparse.category, ProtectedAppCategory.other);
      expect(sparse.isEnabled, isTrue);
      expect(sparse.source, ProtectedAppSource.manual);

      final unknown = ProtectedApp.fromJson(const {
        'packageName': 'com.x',
        'appName': 'X',
        'category': 'crypto_wallet',
        'source': 'remote',
      });
      expect(unknown.category, ProtectedAppCategory.other);
      expect(unknown.source, ProtectedAppSource.manual);
    });

    test('round-trips through JSON', () {
      const app = ProtectedApp(
        packageName: 'com.my.bank',
        appName: 'My Bank',
        category: ProtectedAppCategory.banking,
        isEnabled: false,
      );
      expect(ProtectedApp.fromJson(app.toJson()), app);
    });
  });

  group('ProtectedAppCatalog integrity', () {
    test('has no duplicate package names', () {
      final packages = ProtectedAppCatalog.apps.map((a) => a.packageName);
      expect(packages.toSet().length, packages.length);
    });

    test('every entry is a named, enabled catalog entry', () {
      for (final app in ProtectedAppCatalog.apps) {
        expect(app.packageName, isNotEmpty);
        expect(app.appName, isNotEmpty);
        expect(app.source, ProtectedAppSource.catalog);
        expect(app.isEnabled, isTrue);
      }
    });

    test('core categories are populated and lookups resolve', () {
      expect(
        ProtectedAppCatalog.apps.where(
          (a) => a.category == ProtectedAppCategory.banking,
        ),
        isNotEmpty,
      );
      expect(
        ProtectedAppCatalog.apps.where(
          (a) => a.category == ProtectedAppCategory.payments,
        ),
        isNotEmpty,
      );
      expect(
        ProtectedAppCatalog.byPackage('com.phonepe.app')?.appName,
        'PhonePe',
      );
      expect(ProtectedAppCatalog.byPackage('com.unknown.app'), isNull);
    });
  });

  group('protectedPackagesFor', () {
    test('is the full catalog plus enabled manual additions', () {
      final packages = protectedPackagesFor(const [
        ProtectedApp(packageName: 'com.my.bank', appName: 'Bank'),
        ProtectedApp(packageName: 'com.off', appName: 'Off', isEnabled: false),
      ]);
      expect(packages, [..._catalogPackages, 'com.my.bank']);
    });

    test('with no manual additions it is exactly the catalog', () {
      expect(protectedPackagesFor(const []), _catalogPackages);
    });
  });

  group('ProtectedAppsRepositoryImpl', () {
    test('load returns empty when nothing was ever saved', () async {
      final repo = ProtectedAppsRepositoryImpl(_FakeStore());
      expect(await repo.load(), isEmpty);
    });

    test('save/load round-trips manual entries', () async {
      final store = _FakeStore();
      final repo = ProtectedAppsRepositoryImpl(store);
      const apps = [
        ProtectedApp(packageName: 'com.my.bank', appName: 'My Bank'),
        ProtectedApp(packageName: 'com.x', appName: 'X', isEnabled: false),
      ];
      await repo.save(apps);
      expect(await repo.load(), apps);
    });

    test('drops legacy seeded catalog rows on load (migration)', () async {
      final store = _FakeStore();
      final repo = ProtectedAppsRepositoryImpl(store);
      // An early build stored seeded catalog entries alongside manual ones.
      store.plain[StoreKeys.protectedApps] = jsonEncode([
        ProtectedAppCatalog.apps.first.toJson(),
        const ProtectedApp(packageName: 'com.mine', appName: 'Mine').toJson(),
      ]);
      final loaded = await repo.load();
      expect(loaded.single.packageName, 'com.mine');
    });

    test(
      'corrupt JSON reads as empty (catalog protection is implicit)',
      () async {
        final store = _FakeStore();
        store.plain[StoreKeys.protectedApps] = '{not json';
        final repo = ProtectedAppsRepositoryImpl(store);
        expect(await repo.load(), isEmpty);
      },
    );

    test('one unreadable entry never discards the others (salvage)', () async {
      final store = _FakeStore();
      store.plain[StoreKeys.protectedApps] = jsonEncode([
        const ProtectedApp(packageName: 'com.good', appName: 'Good').toJson(),
        {'packageName': 'com.bad', 'isEnabled': 'not-a-bool'},
        'not even a map',
        const ProtectedApp(packageName: 'com.also', appName: 'Also').toJson(),
      ]);
      final loaded = await ProtectedAppsRepositoryImpl(store).load();
      expect(loaded.map((a) => a.packageName), ['com.good', 'com.also']);
    });
  });

  group('syncProtectedAppsAtBoot', () {
    test('always pushes catalog plus enabled manual additions', () async {
      final engine = _MockEngine();
      final repo = ProtectedAppsRepositoryImpl(_FakeStore());
      when(() => engine.pushProtectedApps(any())).thenAnswer((_) async {});
      await repo.save(const [
        ProtectedApp(packageName: 'com.my.bank', appName: 'Bank'),
      ]);

      await syncProtectedAppsAtBoot(repo, engine);

      final pushed =
          verify(() => engine.pushProtectedApps(captureAny())).captured.single
              as List<String>;
      expect(pushed, [..._catalogPackages, 'com.my.bank']);
      verifyNever(engine.installedPackages);
    });
  });

  group('ProtectedAppsCubit', () {
    late _MockEngine engine;
    late _MockConfig config;
    late ProtectedAppsRepositoryImpl repo;

    setUp(() {
      engine = _MockEngine();
      config = _MockConfig();
      repo = ProtectedAppsRepositoryImpl(_FakeStore());
      when(() => engine.pushProtectedApps(any())).thenAnswer((_) async {});
      when(() => engine.installedPackages()).thenAnswer((_) async => null);
      when(
        () => config.loadBlockTargets(),
      ).thenAnswer((_) async => [_target('com.instagram.android')]);
    });

    ProtectedAppsCubit build() => ProtectedAppsCubit(repo, engine, config);

    List<String> lastPush() =>
        verify(() => engine.pushProtectedApps(captureAny())).captured.last
            as List<String>;

    test(
      'load exposes manual additions and re-pushes catalog + manual',
      () async {
        await repo.save(const [
          ProtectedApp(packageName: 'com.my.bank', appName: 'Bank'),
        ]);
        final cubit = build();
        await cubit.load();

        expect(cubit.state.isLoading, isFalse);
        expect(cubit.state.apps.single.packageName, 'com.my.bank');
        expect(lastPush(), [..._catalogPackages, 'com.my.bank']);
      },
    );

    test('addManual trims, dedupes, and skips catalog packages', () async {
      final cubit = build();
      await cubit.load();

      expect(
        await cubit.addManual(' com.my.bank ', 'My Bank'),
        ProtectedAddResult.added,
      );
      expect(cubit.state.apps.single.appName, 'My Bank');

      expect(
        await cubit.addManual('com.my.bank', 'Duplicate'),
        ProtectedAddResult.duplicate,
      );
      expect(cubit.state.apps, hasLength(1));

      // Already auto-protected — never stored as a manual row.
      expect(
        await cubit.addManual('com.phonepe.app', 'PhonePe'),
        ProtectedAddResult.alreadyCovered,
      );
      expect(cubit.state.apps, hasLength(1));

      // Garbage never persists — it could never match a real event package.
      expect(
        await cubit.addManual('my bank', 'Typo'),
        ProtectedAddResult.invalid,
      );
      expect(cubit.state.apps, hasLength(1));

      expect(await cubit.addManual('com.other', ''), ProtectedAddResult.added);
      expect(cubit.state.apps.last.appName, 'com.other');
      expect(lastPush(), [..._catalogPackages, 'com.my.bank', 'com.other']);
      expect((await repo.load()).length, 2);
    });

    test('remove persists and re-pushes without the package', () async {
      final cubit = build();
      await cubit.load();
      await cubit.addManual('com.a', 'A');
      await cubit.addManual('com.b', 'B');
      await cubit.remove('com.a');

      expect(cubit.state.apps.single.packageName, 'com.b');
      expect(lastPush(), [..._catalogPackages, 'com.b']);
      expect((await repo.load()).single.packageName, 'com.b');
    });

    test('autoProtected lists installed catalog apps; unknown = all', () async {
      final cubit = build();
      await cubit.load();
      expect(cubit.state.installed, isNull);
      expect(cubit.state.autoProtected.length, ProtectedAppCatalog.apps.length);

      when(
        () => engine.installedPackages(),
      ).thenAnswer((_) async => {'com.phonepe.app'});
      final cubit2 = build();
      await cubit2.load();
      expect(cubit2.state.autoProtected.single.appName, 'PhonePe');
    });

    test('needsPinToAdd is true only for blocking-catalog packages', () async {
      final cubit = build();
      await cubit.load();
      expect(cubit.needsPinToAdd('com.instagram.android'), isTrue);
      expect(cubit.needsPinToAdd(' com.instagram.android '), isTrue);
      expect(cubit.needsPinToAdd('com.my.bank'), isFalse);
    });

    test(
      'needsPinToAdd fails closed before load and after a failed load',
      () async {
        // Before load: monitored set unknown → every add costs the PIN.
        expect(build().needsPinToAdd('com.my.bank'), isTrue);

        // Failed load: same — the gate must never silently switch off.
        when(() => config.loadBlockTargets()).thenThrow(Exception('boom'));
        final cubit = build();
        await cubit.load();
        expect(cubit.needsPinToAdd('com.my.bank'), isTrue);
      },
    );

    test('a failed load keeps the apps the repo already returned', () async {
      await repo.save(const [
        ProtectedApp(packageName: 'com.my.bank', appName: 'Bank'),
      ]);
      when(() => config.loadBlockTargets()).thenThrow(Exception('boom'));
      final cubit = build();
      await cubit.load();

      // The screen must never render an empty list over non-empty storage —
      // one add would then overwrite the user's saved protections.
      expect(cubit.state.error, contains('boom'));
      expect(cubit.state.apps.single.packageName, 'com.my.bank');
    });

    blocTest<ProtectedAppsCubit, ProtectedAppsState>(
      'load failure surfaces the error without crashing',
      build: () {
        when(() => config.loadBlockTargets()).thenThrow(Exception('boom'));
        return build();
      },
      act: (cubit) => cubit.load(),
      verify: (cubit) {
        expect(cubit.state.isLoading, isFalse);
        expect(cubit.state.error, contains('boom'));
      },
    );
  });

  group('wire contract', () {
    test('persisted JSON shape stays stable', () async {
      final store = _FakeStore();
      final repo = ProtectedAppsRepositoryImpl(store);
      await repo.save(const [
        ProtectedApp(packageName: 'com.my.bank', appName: 'My Bank'),
      ]);
      final decoded =
          jsonDecode(store.plain[StoreKeys.protectedApps]!) as List<dynamic>;
      expect(decoded.single, {
        'packageName': 'com.my.bank',
        'appName': 'My Bank',
        'category': 'other',
        'isEnabled': true,
        'source': 'manual',
      });
    });
  });
}
