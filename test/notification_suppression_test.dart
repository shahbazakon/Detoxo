import 'package:detoxo/core/constants/channel_constants.dart';
import 'package:detoxo/core/platform/platform_capabilities.dart';
import 'package:detoxo/core/platform_channels/engine_channel.dart';
import 'package:detoxo/core/storage/local_store.dart';
import 'package:detoxo/core/theme/app_theme.dart';
import 'package:detoxo/features/blocking/shared/data/repositories/engine_repository_impl.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/app_settings.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
import 'package:detoxo/features/permissions/data/repositories/permission_repository_impl.dart';
import 'package:detoxo/features/permissions/domain/entities/permission_status.dart';
import 'package:detoxo/features/permissions/domain/repositories/permission_repository.dart';
import 'package:detoxo/features/permissions/presentation/permission_actions.dart';
import 'package:detoxo/features/permissions/presentation/permissions_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockChannel extends Mock implements EngineChannel {}

class _MockStore extends Mock implements LocalStore {}

/// Records what the funnel actually asked the OS for, so a declined disclosure
/// can be shown to reach nothing.
class _RecordingRepo implements PermissionRepository {
  final List<AppPermission> requested = [];

  @override
  Future<void> request(AppPermission permission) async =>
      requested.add(permission);

  @override
  Future<PermissionStatus> status(AppPermission permission) async =>
      PermissionStatus(kind: permission, state: PermissionState.denied);

  @override
  Future<List<PermissionStatus>> statuses() async => [
    for (final p in AppPermission.values) await status(p),
  ];

  @override
  Future<Set<AppPermission>> lastKnownGranted() async => const {};

  @override
  Future<bool> installedOutsidePlay() async => false;

  @override
  Future<void> openAppSettings() async {}
}

bool? _lastResult;

/// M5 — notification suppression, Dart side.
///
/// The suppression *decision* is native and pinned by `SuppressionDecisionTest`
/// (which apps, and when). Nothing about it is derived here on purpose: Dart
/// only owns the on/off switch and the grant. These tests pin exactly that
/// boundary — that the switch reaches native, and that the seventh funnel entry
/// behaves like the optional, restricted-settings permission it is.
void main() {
  setUp(() => PlatformCapabilities.debugForceAndroid = true);
  tearDown(() => PlatformCapabilities.debugForceAndroid = null);

  group('the suppression switch reaches native', () {
    test('defaults to off and survives a JSON round-trip', () {
      expect(const AppSettings().suppressNotifications, isFalse);

      final on = const AppSettings().copyWith(suppressNotifications: true);
      expect(AppSettings.fromJson(on.toJson()).suppressNotifications, isTrue);

      // Absent key (an upgrade from a build before M5) reads as off, never as
      // a silently-enabled listener.
      final legacy = on.toJson()..remove('suppressNotifications');
      expect(AppSettings.fromJson(legacy).suppressNotifications, isFalse);
    });

    test('rides the existing pushSettings arm', () async {
      final channel = _MockChannel();
      when(() => channel.pushSettings(any())).thenAnswer((_) async {});
      final engine = EngineRepositoryImpl(channel);

      await engine.pushSettings(
        const AppSettings().copyWith(suppressNotifications: true),
      );

      final pushed =
          verify(() => channel.pushSettings(captureAny())).captured.single
              as Map<String, dynamic>;
      expect(pushed['suppressNotifications'], isTrue);
      // No second push exists: the suppressed SET is never sent, only the flag.
      expect(pushed.keys.where((k) => k.startsWith('suppressed')), isEmpty);
    });
  });

  group('AppPermission.notificationListener', () {
    late _MockChannel channel;
    late _MockStore store;
    late PermissionRepositoryImpl repo;

    setUp(() {
      channel = _MockChannel();
      store = _MockStore();
      when(() => store.read(any())).thenReturn(null);
      when(() => store.write(any(), any())).thenAnswer((_) async {});
      repo = PermissionRepositoryImpl(channel, store);
    });

    test('is optional, so it cannot gate the splash', () {
      expect(AppPermission.notificationListener.required, isFalse);
      // ECM / restricted settings swallow this grant on a sideloaded install,
      // exactly like accessibility and overlay — so the recovery sheet applies.
      expect(
        AppPermission.notificationListener.restrictedWhenSideloaded,
        isTrue,
      );
    });

    test('reads through the tri-state channel path', () async {
      when(
        () => channel.invokeBoolOrNull(
          ChannelMethods.isNotificationListenerEnabled,
        ),
      ).thenAnswer((_) async => true);

      final status = await repo.status(AppPermission.notificationListener);
      expect(status.state, PermissionState.granted);
    });

    test('two failed reads yield unknown, never denied', () async {
      when(
        () => channel.invokeBoolOrNull(
          ChannelMethods.isNotificationListenerEnabled,
        ),
      ).thenAnswer((_) async => null);

      final status = await repo.status(AppPermission.notificationListener);
      expect(status.state, PermissionState.unknown);
      verify(
        () => channel.invokeBoolOrNull(
          ChannelMethods.isNotificationListenerEnabled,
        ),
      ).called(2);
    });

    test('request opens the system notification-access screen', () async {
      when(
        () => channel.openNotificationListenerSettings(),
      ).thenAnswer((_) async {});

      await repo.request(AppPermission.notificationListener);

      verify(() => channel.openNotificationListenerSettings()).called(1);
    });

    testWidgets('declining the disclosure is a refusal, not a request', (
      tester,
    ) async {
      // The consent path. Turning the switch on shows the Play-required
      // disclosure; tapping "Not now" after reading what the permission does
      // must not reach cubit.request(), and — via the false return — must not
      // let the caller record the feature as enabled.
      final repo = _RecordingRepo();
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: BlocProvider(
            create: (_) => PermissionsCubit(repo),
            child: Builder(
              builder: (context) => Scaffold(
                body: ElevatedButton(
                  onPressed: () async {
                    _lastResult = await requestPermission(
                      context,
                      AppPermission.notificationListener,
                    );
                  },
                  child: const Text('go'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.text('How Detoxo uses Notification access'), findsOneWidget);

      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();

      expect(_lastResult, isFalse, reason: 'a decline must report refusal');
      expect(repo.requested, isEmpty, reason: 'no grant may be requested');
    });

    test('every permission is read concurrently, not one after another', () async {
      // The fan-out sits inside the splash gate's Future.wait, and each leg can
      // sleep 150 ms retrying a null read. Serially that was N round trips of
      // added cold-start latency; regressing it is invisible without this test.
      var live = 0;
      var peak = 0;
      when(() => channel.invokeBoolOrNull(any())).thenAnswer((_) async {
        live++;
        peak = peak > live ? peak : live;
        await Future<void>.delayed(const Duration(milliseconds: 20));
        live--;
        return true;
      });

      await repo.statuses();

      expect(peak, greaterThan(1), reason: 'reads must overlap');
    });
  });
}
