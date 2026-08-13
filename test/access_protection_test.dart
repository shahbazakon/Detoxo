import 'dart:convert';

import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/core/platform_channels/engine_channel.dart';
import 'package:detoxo/core/storage/local_store.dart';
import 'package:detoxo/features/access_protection/data/repositories/pin_repository_impl.dart';
import 'package:detoxo/features/access_protection/domain/entities/pin_config.dart';
import 'package:detoxo/features/access_protection/domain/pin_hasher.dart';
import 'package:detoxo/features/access_protection/domain/repositories/pin_repository.dart';
import 'package:detoxo/features/access_protection/presentation/pin_auto_relock.dart';
import 'package:detoxo/features/access_protection/presentation/pin_cubit.dart';
import 'package:detoxo/features/access_protection/presentation/pin_gate.dart';
import 'package:detoxo/features/access_protection/presentation/pin_setup_screen.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:local_auth/local_auth.dart';
import 'package:mocktail/mocktail.dart';

/// In-memory PIN repository for tests (no secure storage / network).
class _FakePinRepo implements PinRepository {
  /// Seedable so tests can load configs no UI path would write.
  PinConfig stored = const PinConfig();

  /// Last value pushed through [setSecureScreen] (null = never called).
  bool? secureScreenApplied;
  int screenOffMillis = 0;

  @override
  Future<PinConfig> load() async => stored;

  @override
  Future<void> save(PinConfig config) async => stored = config;

  @override
  Future<void> setSecureScreen({required bool enabled}) async =>
      secureScreenApplied = enabled;

  @override
  Future<int> lastScreenOffMillis() async => screenOffMillis;
}

/// In-memory [LocalStore] (no Hive / secure storage) for repository tests.
class _FakeStore implements LocalStore {
  final Map<String, String> plain = {};
  final Map<String, String> secrets = {};

  @override
  String? read(String key) => plain[key];
  @override
  Future<void> write(String key, String value) async => plain[key] = value;
  @override
  Future<void> delete(String key) async => plain.remove(key);
  @override
  Future<String?> readSecret(String key) async => secrets[key];
  @override
  Future<void> writeSecret(String key, String value) async =>
      secrets[key] = value;
  @override
  Future<void> deleteSecret(String key) async => secrets.remove(key);
  @override
  Future<void> clearAll() async {
    plain.clear();
    secrets.clear();
  }
}

class _MockLocalAuth extends Mock implements LocalAuthentication {}

void main() {
  group('PinCubit.expectedLength', () {
    test('custom uses the stored secret length', () async {
      final cubit = PinCubit(_FakePinRepo());
      await cubit.setup(
        type: PinType.custom,
        secret: '123456',
        scopes: {PinScope.app},
      );
      expect(cubit.expectedLength, 6);
    });

    test('date is 8 (ddMMyyyy) and time is 4 (HHmm)', () async {
      final cubit = PinCubit(_FakePinRepo());
      await cubit.setup(type: PinType.date, secret: '', scopes: {PinScope.app});
      expect(cubit.expectedLength, 8);
      await cubit.setup(type: PinType.time, secret: '', scopes: {PinScope.app});
      expect(cubit.expectedLength, 4);
    });
  });

  group('PinHasher', () {
    test('verifies the right secret and rejects the wrong one', () {
      final salt = PinHasher.newSalt();
      final hash = PinHasher.hash(salt, '1234');
      expect(PinHasher.verify(salt, hash, '1234'), isTrue);
      expect(PinHasher.verify(salt, hash, '0000'), isFalse);
    });

    test('different salts produce different hashes for the same secret', () {
      final a = PinHasher.newSalt();
      final b = PinHasher.newSalt();
      expect(a, isNot(b));
      expect(PinHasher.hash(a, '1234'), isNot(PinHasher.hash(b, '1234')));
    });

    test('verify is false when salt or hash is empty', () {
      expect(PinHasher.verify('', 'x', '1234'), isFalse);
      expect(PinHasher.verify('salt', '', '1234'), isFalse);
    });
  });

  group('PinCubit custom verify', () {
    test('accepts the configured PIN and rejects others (hashed)', () async {
      final cubit = PinCubit(_FakePinRepo());
      await cubit.setup(
        type: PinType.custom,
        secret: '1357',
        scopes: {PinScope.app},
      );
      // Stored hashed, not in plaintext.
      expect(cubit.state.secretHash, isNotEmpty);
      expect(cubit.state.salt, isNotEmpty);
      expect(await cubit.verify('1357'), isTrue);
      expect(await cubit.verify('0000'), isFalse);
    });

    test('disable() clears the configured lock', () async {
      final cubit = PinCubit(_FakePinRepo());
      await cubit.setup(
        type: PinType.custom,
        secret: '1357',
        scopes: {PinScope.app},
      );
      await cubit.disable();
      expect(cubit.state.isConfigured, isFalse);
      expect(cubit.state.type, PinType.none);
      expect(cubit.state.secretHash, isEmpty);
    });
  });

  group('no recovery backdoor', () {
    // A build once shipped a hardcoded '000000' recovery code that unlocked any
    // PIN. Nothing but the real PIN may ever verify.
    test('the retired dev recovery code does not unlock', () async {
      final cubit = PinCubit(_FakePinRepo());
      await cubit.setup(
        type: PinType.custom,
        secret: '1357',
        scopes: {PinScope.app},
      );
      expect(await cubit.verify('000000'), isFalse);
      expect(await cubit.verify('1357'), isTrue);
    });

    test('a stored config carries no email or other identifier', () async {
      final cubit = PinCubit(_FakePinRepo());
      await cubit.setup(
        type: PinType.custom,
        secret: '1357',
        scopes: {PinScope.app},
      );
      expect(cubit.state.toJson().keys, isNot(contains('verifiedEmail')));
    });

    test('a legacy config with verifiedEmail still loads', () {
      // Older installs persisted the key; fromJson must ignore it, not throw.
      final config = PinConfig.fromJson(const {
        'type': 'CUSTOM',
        'secretHash': 'abc',
        'salt': 'def',
        'secretLength': 4,
        'scopes': ['APP'],
        'verifiedEmail': 'legacy@example.com',
        'retryCount': 0,
        'biometricEnabled': false,
      });
      expect(config.type, PinType.custom);
      expect(config.scopes, const {PinScope.app});
    });
  });

  group('requirePin short-circuit', () {
    testWidgets('returns true when no PIN is configured', (tester) async {
      final cubit = PinCubit(_FakePinRepo());
      late bool result;
      await tester.pumpWidget(
        MaterialApp(
          home: BlocProvider.value(
            value: cubit,
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () async =>
                    result = await requirePin(context, PinScope.settings),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pump();
      expect(result, isTrue);
    });

    testWidgets('returns true when the scope is not guarded', (tester) async {
      final cubit = PinCubit(_FakePinRepo());
      await cubit.setup(
        type: PinType.custom,
        secret: '1234',
        scopes: {PinScope.app}, // guards launch only, not settings
      );
      late bool result;
      await tester.pumpWidget(
        MaterialApp(
          home: BlocProvider.value(
            value: cubit,
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () async =>
                    result = await requirePin(context, PinScope.settings),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pump();
      expect(result, isTrue);
    });

    testWidgets('returns true when appLocker is configured but not guarded', (
      tester,
    ) async {
      final cubit = PinCubit(_FakePinRepo());
      await cubit.setup(
        type: PinType.custom,
        secret: '1234',
        scopes: {PinScope.app}, // does not guard the app locker
      );
      late bool result;
      await tester.pumpWidget(
        MaterialApp(
          home: BlocProvider.value(
            value: cubit,
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () async =>
                    result = await requirePin(context, PinScope.appLocker),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pump();
      expect(result, isTrue);
    });
  });

  group('requirePin gating', () {
    testWidgets('shows the lock screen when appLocker is guarded', (
      tester,
    ) async {
      final cubit = PinCubit(_FakePinRepo());
      await cubit.setup(
        type: PinType.custom,
        secret: '1234',
        scopes: {PinScope.appLocker},
      );
      // The gate pushes onto the root navigator, so PinCubit must sit above
      // MaterialApp (as it does in main.dart) for the lock screen to find it.
      await tester.pumpWidget(
        BlocProvider.value(
          value: cubit,
          child: MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                // Fire-and-forget: the future resolves only once the user
                // unlocks/cancels, so we just assert the gate is shown.
                onPressed: () => requirePin(context, PinScope.appLocker),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pump(); // begin pushing the lock-screen route
      // GlassScaffold runs an infinite ambient animation, so settle by a fixed
      // duration rather than pumpAndSettle (which would never converge).
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Confirm to manage locked apps'), findsOneWidget);
    });

    testWidgets('cancelling the gate resolves false', (tester) async {
      final cubit = PinCubit(_FakePinRepo());
      await cubit.setup(
        type: PinType.custom,
        secret: '1234',
        scopes: {PinScope.appLocker},
      );
      bool? result;
      await tester.pumpWidget(
        BlocProvider.value(
          value: cubit,
          child: MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () async =>
                    result = await requirePin(context, PinScope.appLocker),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      // The ✕ affordance only exists on cancellable gates; tapping it must
      // resolve the guard future to false — every protected mutation in
      // settings trusts this.
      await tester.tap(find.byTooltip('Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(result, isFalse);
    });
  });

  group('PinCubit lockout ladder', () {
    test('locks out only after exceeding the 5 free attempts', () async {
      final cubit = PinCubit(_FakePinRepo());
      await cubit.setup(
        type: PinType.custom,
        secret: '1234',
        scopes: {PinScope.app},
      );

      for (var i = 0; i < 5; i++) {
        expect(await cubit.verify('0000'), isFalse);
      }
      expect(cubit.state.isLockedOut, isFalse); // 5 attempts: no lockout yet

      expect(await cubit.verify('0000'), isFalse); // 6th failure
      expect(cubit.state.isLockedOut, isTrue);
      expect(cubit.state.lockedUntil, isNotNull);

      // While locked out, even the correct PIN is refused.
      expect(await cubit.verify('1234'), isFalse);
    });
  });

  group('PinCubit input hardening', () {
    test('setup() rejects a custom PIN shorter than 4 digits', () async {
      final cubit = PinCubit(_FakePinRepo());
      await expectLater(
        cubit.setup(
          type: PinType.custom,
          secret: '123',
          scopes: {PinScope.app},
        ),
        throwsArgumentError,
      );
      expect(cubit.state.isConfigured, isFalse);
    });

    test('expectedLength floors at 4 when secretLength is corrupted', () async {
      // No shipped schema writes secretLength 0 for a custom PIN; if a blob
      // ever carries it, 0 >= 0 would swallow the first keypress forever.
      final repo = _FakePinRepo()
        ..stored = const PinConfig(
          type: PinType.custom,
          secretHash: 'h',
          salt: 's',
          scopes: {PinScope.app},
        );
      final cubit = PinCubit(repo);
      await cubit.load();
      expect(cubit.expectedLength, 4);
    });
  });

  group('AutoLockPolicy.shouldRelock', () {
    const appPin = PinConfig(type: PinType.custom, scopes: {PinScope.app});
    final now = DateTime(2026, 8, 7, 12);
    DateTime pausedFor(Duration d) => now.subtract(d);

    bool relock(PinConfig config, {DateTime? pausedAt, int screenOff = 0}) =>
        AutoLockPolicy.shouldRelock(
          config: config,
          pausedAt: pausedAt,
          now: now,
          lastScreenOffMillis: screenOff,
        );

    test('never relocks when unconfigured or app scope unguarded', () {
      const unconfigured = PinConfig(
        autoLock: AutoLockTimeout.immediately,
        scopes: {PinScope.app},
      );
      const settingsOnly = PinConfig(
        type: PinType.custom,
        scopes: {PinScope.settings},
        autoLock: AutoLockTimeout.immediately,
      );
      expect(relock(unconfigured, pausedAt: now), isFalse);
      expect(relock(settingsOnly, pausedAt: now), isFalse);
    });

    test('no pause stamp means no relock', () {
      final config = appPin.copyWith(autoLock: AutoLockTimeout.immediately);
      expect(relock(config), isFalse);
    });

    test('never: stays unlocked regardless of time away', () {
      final config = appPin.copyWith(autoLock: AutoLockTimeout.never);
      expect(
        relock(config, pausedAt: pausedFor(const Duration(days: 2))),
        isFalse,
      );
    });

    test('immediately: relocks on any pause', () {
      final config = appPin.copyWith(autoLock: AutoLockTimeout.immediately);
      expect(relock(config, pausedAt: now), isTrue);
    });

    test('timed options relock at their boundary, not before', () {
      const cases = {
        AutoLockTimeout.s15: Duration(seconds: 15),
        AutoLockTimeout.s30: Duration(seconds: 30),
        AutoLockTimeout.m1: Duration(minutes: 1),
        AutoLockTimeout.m5: Duration(minutes: 5),
      };
      for (final MapEntry(key: timeout, value: delay) in cases.entries) {
        final config = appPin.copyWith(autoLock: timeout);
        final justUnder = delay - const Duration(seconds: 1);
        expect(relock(config, pausedAt: pausedFor(justUnder)), isFalse);
        expect(relock(config, pausedAt: pausedFor(delay)), isTrue);
      }
    });

    test('screenOff: relocks only if the screen went off during the pause', () {
      final config = appPin.copyWith(autoLock: AutoLockTimeout.screenOff);
      final pausedAt = pausedFor(const Duration(minutes: 10));
      final beforePause = pausedAt
          .subtract(const Duration(minutes: 1))
          .millisecondsSinceEpoch;
      final afterPause = pausedAt
          .add(const Duration(minutes: 1))
          .millisecondsSinceEpoch;
      expect(relock(config, pausedAt: pausedAt), isFalse); // never seen
      expect(
        relock(config, pausedAt: pausedAt, screenOff: beforePause),
        isFalse,
      );
      expect(relock(config, pausedAt: pausedAt, screenOff: afterPause), isTrue);
    });
  });

  group('PinCubit.matches with a fixed clock', () {
    test('date PIN is ddMMyyyy of today', () {
      const config = PinConfig(type: PinType.date, scopes: {PinScope.app});
      final now = DateTime(2026, 8, 7, 15, 30);
      expect(PinCubit.matches(config, '07082026', now), isTrue);
      expect(PinCubit.matches(config, '08072026', now), isFalse);
    });

    test('time PIN is HHmm of right now, zero-padded', () {
      const config = PinConfig(type: PinType.time, scopes: {PinScope.app});
      expect(
        PinCubit.matches(config, '0905', DateTime(2026, 8, 7, 9, 5)),
        isTrue,
      );
      expect(
        PinCubit.matches(config, '95', DateTime(2026, 8, 7, 9, 5)),
        isFalse,
      );
      expect(
        PinCubit.matches(config, '0905', DateTime(2026, 8, 7, 9, 6)),
        isFalse,
      );
    });

    test('an unconfigured type never matches', () {
      const config = PinConfig(scopes: {PinScope.app});
      expect(PinCubit.matches(config, '', DateTime(2026)), isFalse);
    });
  });

  group('PinConfig json & copyWith', () {
    test('roundtrips the auto-lock fields', () {
      const config = PinConfig(
        type: PinType.custom,
        secretHash: 'h',
        salt: 's',
        secretLength: 4,
        scopes: {PinScope.app, PinScope.settings},
        biometricEnabled: true,
        autoLock: AutoLockTimeout.s30,
        secureScreen: true,
      );
      expect(PinConfig.fromJson(config.toJson()), config);
    });

    test('a pre-auto-lock config upgrades to safe defaults', () {
      // Stored by a build that predates autoLock/secureScreen.
      final config = PinConfig.fromJson(const {
        'type': 'CUSTOM',
        'secretHash': 'abc',
        'salt': 'def',
        'secretLength': 4,
        'scopes': ['DETOXO_APP'],
      });
      expect(config.autoLock, AutoLockTimeout.m1);
      expect(config.secureScreen, isFalse);
    });

    test('copyWith keeps lockedUntil unless clearLockout is set', () {
      final locked = PinConfig(
        type: PinType.custom,
        scopes: const {PinScope.app},
        lockedUntil: DateTime(2026, 8, 7),
      );
      expect(locked.copyWith(retryCount: 1).lockedUntil, isNotNull);
      expect(locked.copyWith(clearLockout: true).lockedUntil, isNull);
    });
  });

  group('PinRepositoryImpl', () {
    // A real EngineChannel is inert on the test host: PlatformCapabilities
    // short-circuits every invoke off-Android.
    PinRepositoryImpl repoWith(_FakeStore store) =>
        PinRepositoryImpl(store, EngineChannel());

    test('returns the default config when nothing is stored', () async {
      expect(await repoWith(_FakeStore()).load(), const PinConfig());
    });

    test('migrates a legacy plaintext PIN to a salted hash on load', () async {
      final store = _FakeStore();
      store.secrets[StoreKeys.pinConfig] = jsonEncode({
        'type': 'CUSTOM',
        'secret': '4321', // pre-hashing plaintext
        'scopes': ['DETOXO_APP'],
      });

      final config = await repoWith(store).load();

      expect(config.secretHash, isNotEmpty);
      expect(config.salt, isNotEmpty);
      expect(config.secretLength, 4);
      expect(PinHasher.verify(config.salt, config.secretHash, '4321'), isTrue);

      // The migrated form is persisted and the plaintext is gone for good.
      final persisted =
          jsonDecode(store.secrets[StoreKeys.pinConfig]!)
              as Map<String, dynamic>;
      expect(persisted.containsKey('secret'), isFalse);
      expect(persisted['secretHash'], config.secretHash);
    });

    test('a corrupted blob fails open to the default config', () async {
      // A throw here would reject the splash's Future.wait and strand the app
      // on the spinner forever — the fix catches and falls back to defaults.
      final store = _FakeStore();
      store.secrets[StoreKeys.pinConfig] = 'not-json{{{';
      expect(await repoWith(store).load(), const PinConfig());

      store.secrets[StoreKeys.pinConfig] = '[1, 2, 3]'; // decodes, wrong shape
      expect(await repoWith(store).load(), const PinConfig());
    });
  });

  group('PinCubit biometrics', () {
    late _MockLocalAuth auth;
    late PinCubit cubit;

    setUp(() {
      auth = _MockLocalAuth();
      cubit = PinCubit(_FakePinRepo(), localAuth: auth);
    });

    test(
      'canUseBiometrics needs device support and enrolled biometrics',
      () async {
        when(() => auth.isDeviceSupported()).thenAnswer((_) async => true);
        when(() => auth.canCheckBiometrics).thenAnswer((_) async => true);
        expect(await cubit.canUseBiometrics(), isTrue);

        when(() => auth.isDeviceSupported()).thenAnswer((_) async => false);
        expect(await cubit.canUseBiometrics(), isFalse);
      },
    );

    test('canUseBiometrics is false when the platform throws', () async {
      when(
        () => auth.isDeviceSupported(),
      ).thenThrow(PlatformException(code: 'no_hw'));
      expect(await cubit.canUseBiometrics(), isFalse);
    });

    test('authenticateBiometric returns the OS sheet result', () async {
      when(() => auth.canCheckBiometrics).thenAnswer((_) async => true);
      when(
        () => auth.authenticate(
          localizedReason: any(named: 'localizedReason'),
          persistAcrossBackgrounding: any(named: 'persistAcrossBackgrounding'),
        ),
      ).thenAnswer((_) async => true);
      expect(await cubit.authenticateBiometric(), isTrue);
    });

    test(
      'authenticateBiometric is false when unsupported or throwing',
      () async {
        when(() => auth.canCheckBiometrics).thenAnswer((_) async => false);
        when(() => auth.isDeviceSupported()).thenAnswer((_) async => false);
        expect(await cubit.authenticateBiometric(), isFalse);

        when(() => auth.canCheckBiometrics).thenAnswer((_) async => true);
        when(
          () => auth.authenticate(
            localizedReason: any(named: 'localizedReason'),
            persistAcrossBackgrounding: any(
              named: 'persistAcrossBackgrounding',
            ),
          ),
        ).thenThrow(PlatformException(code: 'locked_out'));
        expect(await cubit.authenticateBiometric(), isFalse);
      },
    );
  });

  group('secure-screen choke points', () {
    test('setup, load and disable push the FLAG_SECURE state', () async {
      final repo = _FakePinRepo();
      final cubit = PinCubit(repo);

      await cubit.setup(
        type: PinType.custom,
        secret: '1234',
        scopes: {PinScope.app},
        secureScreen: true,
      );
      expect(repo.secureScreenApplied, isTrue);

      await cubit.load(); // re-applies what is persisted
      expect(repo.secureScreenApplied, isTrue);

      await cubit.disable(); // turning the lock off always clears the flag
      expect(repo.secureScreenApplied, isFalse);
    });
  });

  group('PinAutoRelock', () {
    Future<_FakePinRepo> pumpRelockApp(
      WidgetTester tester, {
      AutoLockTimeout autoLock = AutoLockTimeout.immediately,
    }) async {
      final repo = _FakePinRepo();
      final cubit = PinCubit(repo);
      await cubit.setup(
        type: PinType.custom,
        secret: '1234',
        scopes: {PinScope.app},
        autoLock: autoLock,
      );
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Scaffold(body: Text('home')),
          ),
        ],
      );
      await tester.pumpWidget(
        BlocProvider.value(
          value: cubit,
          child: PinAutoRelock(
            router: router,
            child: MaterialApp.router(routerConfig: router),
          ),
        ),
      );
      return repo;
    }

    void backgroundAndResume(WidgetTester tester) {
      tester.binding
        ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
        ..handleAppLifecycleStateChanged(AppLifecycleState.hidden)
        ..handleAppLifecycleStateChanged(AppLifecycleState.paused)
        ..handleAppLifecycleStateChanged(AppLifecycleState.hidden)
        ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
        ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }

    testWidgets('pushes the lock screen on resume (immediately)', (
      tester,
    ) async {
      await pumpRelockApp(tester);
      expect(find.text('home'), findsOneWidget);

      backgroundAndResume(tester);
      await tester.pump(); // let _maybeRelock complete + route push begin
      await tester.pump(const Duration(milliseconds: 400)); // glass anims

      expect(find.text('Enter your PIN'), findsOneWidget);
    });

    testWidgets('never stacks a second lock over a visible one', (
      tester,
    ) async {
      await pumpRelockApp(tester);

      backgroundAndResume(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      backgroundAndResume(tester); // background again at the lock itself
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Enter your PIN'), findsOneWidget);
    });

    testWidgets('screenOff: relocks only if the screen went off while away', (
      tester,
    ) async {
      final repo = await pumpRelockApp(
        tester,
        autoLock: AutoLockTimeout.screenOff,
      );

      // Screen never went off during the pause: stays unlocked.
      backgroundAndResume(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Enter your PIN'), findsNothing);

      // A screen-off stamp after the pause stamp: relocks.
      repo.screenOffMillis = DateTime.now()
          .add(const Duration(hours: 1))
          .millisecondsSinceEpoch;
      backgroundAndResume(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Enter your PIN'), findsOneWidget);
    });
  });

  group('PinSetupScreen save flow', () {
    // Provider above MaterialApp: the pushed route lives on the root
    // navigator, whose context sits above anything inside `home`.
    Widget host(PinCubit cubit) => BlocProvider.value(
      value: cubit,
      child: MaterialApp(
        theme: AppTheme.dark(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const PinSetupScreen(),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    Future<void> openSetup(WidgetTester tester, PinCubit cubit) async {
      await tester.pumpWidget(host(cubit));
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    Finder toggleIn(String tileTitle) => find.descendant(
      of: find.widgetWithText(AppToggleTile, tileTitle),
      matching: find.byType(AppToggle),
    );

    // The setup body is a lazy ListView: offscreen rows have no elements yet,
    // so targets below the fold need scrollUntilVisible, not ensureVisible.
    Future<void> scrollTo(WidgetTester tester, Finder finder, double delta) =>
        tester.scrollUntilVisible(
          finder,
          delta,
          scrollable: find.byType(Scrollable).first,
        );

    testWidgets('save wires secureScreen and autoLock into setup()', (
      tester,
    ) async {
      final repo = _FakePinRepo();
      final cubit = PinCubit(repo);
      await openSetup(tester, cubit);

      await tester.enterText(find.byType(TextField).first, '2468');
      await tester.enterText(find.byType(TextField).last, '2468');
      await scrollTo(tester, find.text('Hide screen in Recents'), 200);
      await tester.tap(toggleIn('Hide screen in Recents'));
      await tester.pump();
      await scrollTo(tester, find.text('Save PIN'), 200);
      await tester.tap(find.text('Save PIN'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(cubit.state.type, PinType.custom);
      expect(cubit.state.secureScreen, isTrue);
      expect(cubit.state.autoLock, AutoLockTimeout.m1); // untouched default
      expect(repo.secureScreenApplied, isTrue);

      // Let the "PIN saved." toast time out, then fire the zero-duration
      // timer flutter_animate schedules when the exit animation rebuilds.
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
    });

    testWidgets('rejects short PIN, mismatch and empty scopes', (tester) async {
      final cubit = PinCubit(_FakePinRepo());
      await openSetup(tester, cubit);
      final firstField = find.byType(TextField).first;

      // Too short.
      await tester.enterText(firstField, '12');
      await scrollTo(tester, find.text('Save PIN'), 200);
      await tester.tap(find.text('Save PIN'));
      await tester.pump();
      expect(cubit.state.isConfigured, isFalse);

      // Mismatched confirmation. (Scroll anchor is the unique section header,
      // rendered uppercased; a `.first` finder throws while zero TextFields
      // are built off-screen.)
      await scrollTo(tester, find.text('YOUR PIN'), -200);
      await tester.enterText(firstField, '1234');
      await tester.enterText(find.byType(TextField).last, '9999');
      await scrollTo(tester, find.text('Save PIN'), 200);
      await tester.tap(find.text('Save PIN'));
      await tester.pump();
      expect(cubit.state.isConfigured, isFalse);

      // No scope selected.
      await scrollTo(tester, find.text('YOUR PIN'), -200);
      await tester.enterText(find.byType(TextField).last, '1234');
      await scrollTo(tester, find.text('Opening Detoxo'), 200);
      await tester.tap(toggleIn('Opening Detoxo'));
      await tester.pump();
      await scrollTo(tester, find.text('Changing protected settings'), 200);
      await tester.tap(toggleIn('Changing protected settings'));
      await tester.pump();
      await scrollTo(tester, find.text('Save PIN'), 200);
      await tester.tap(find.text('Save PIN'));
      await tester.pump();
      expect(cubit.state.isConfigured, isFalse);

      // Let the validation toasts time out, then fire flutter_animate's
      // zero-duration exit-rebuild timer.
      await tester.pump(const Duration(seconds: 5));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump();
    });
  });
}
