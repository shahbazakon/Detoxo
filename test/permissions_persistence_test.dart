import 'dart:convert';

import 'package:detoxo/core/platform/platform_capabilities.dart';
import 'package:detoxo/core/platform_channels/engine_channel.dart';
import 'package:detoxo/core/storage/local_store.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
import 'package:detoxo/features/permissions/data/repositories/permission_repository_impl.dart';
import 'package:detoxo/features/permissions/domain/entities/permission_status.dart';
import 'package:detoxo/features/permissions/domain/repositories/permission_repository.dart';
import 'package:detoxo/features/permissions/presentation/permissions_cubit.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockChannel extends Mock implements EngineChannel {}

class _MockStore extends Mock implements LocalStore {}

/// Fake repo for the cubit-gate tests: per-permission states + a canned
/// last-known-granted set.
class _FakeRepo implements PermissionRepository {
  _FakeRepo({this.states = const {}, this.granted = const {}});

  final Map<AppPermission, PermissionState> states;
  final Set<AppPermission> granted;

  @override
  Future<Set<AppPermission>> lastKnownGranted() async => granted;

  @override
  Future<bool> installedOutsidePlay() async => true;

  @override
  Future<void> openAppSettings() async {}

  @override
  Future<void> request(AppPermission permission) async {}

  @override
  Future<PermissionStatus> status(AppPermission permission) async =>
      PermissionStatus(
        kind: permission,
        state: states[permission] ?? PermissionState.denied,
      );

  @override
  Future<List<PermissionStatus>> statuses() async => [
    for (final p in AppPermission.values) await status(p),
  ];
}

void main() {
  // The impl short-circuits off-Android; the host runner isn't Android.
  setUp(() => PlatformCapabilities.debugForceAndroid = true);
  tearDown(() => PlatformCapabilities.debugForceAndroid = null);

  group('PermissionRepositoryImpl tri-state reads', () {
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

    test('two failed reads yield unknown, never denied', () async {
      when(() => channel.invokeBoolOrNull(any())).thenAnswer((_) async => null);
      final s = await repo.status(AppPermission.accessibility);
      expect(s.state, PermissionState.unknown);
      // One retry happened: two reads total.
      verify(() => channel.invokeBoolOrNull(any())).called(2);
    });

    test('a successful retry yields granted', () async {
      var calls = 0;
      when(
        () => channel.invokeBoolOrNull(any()),
      ).thenAnswer((_) async => calls++ == 0 ? null : true);
      final s = await repo.status(AppPermission.overlay);
      expect(s.state, PermissionState.granted);
    });

    test('a definitive false is denied (no retry)', () async {
      when(
        () => channel.invokeBoolOrNull(any()),
      ).thenAnswer((_) async => false);
      final s = await repo.status(AppPermission.accessibility);
      expect(s.state, PermissionState.denied);
      verify(() => channel.invokeBoolOrNull(any())).called(1);
    });

    test('a notification plugin throw yields unknown, not a rejection', () async {
      // permission_handler has no host implementation — its channel call
      // throws, which used to reject the splash's Future.wait and hang the app.
      final s = await repo.status(AppPermission.notifications);
      expect(s.state, PermissionState.unknown);
    });

    test('statuses() persists granted, drops denied, keeps unknown', () async {
      // Previously granted: accessibility + overlay + usageAccess.
      when(
        () => store.read(StoreKeys.grantedPermissions),
      ).thenReturn(jsonEncode(['accessibility', 'overlay', 'usageAccess']));
      // Live reads: accessibility unknown (kept), overlay denied (dropped),
      // battery granted (added), everything else denied.
      when(
        () => channel.invokeBoolOrNull(any()),
      ).thenAnswer((_) async => false);
      when(
        () => channel.invokeBoolOrNull('isAccessibilityEnabled'),
      ).thenAnswer((_) async => null);
      when(
        () => channel.invokeBoolOrNull('isIgnoringBatteryOptimizations'),
      ).thenAnswer((_) async => true);

      await repo.statuses();

      final written =
          verify(
                () => store.write(StoreKeys.grantedPermissions, captureAny()),
              ).captured.single
              as String;
      expect((jsonDecode(written) as List).toSet(), {
        'accessibility',
        'batteryOptimization',
      });
    });

    test('lastKnownGranted tolerates a corrupt blob', () async {
      when(
        () => store.read(StoreKeys.grantedPermissions),
      ).thenReturn('not json');
      expect(await repo.lastKnownGranted(), isEmpty);
    });

    test('lastKnownGranted decodes stored names', () async {
      when(() => store.read(StoreKeys.grantedPermissions)).thenReturn(
        jsonEncode(['accessibility', 'overlay', 'no_such_permission']),
      );
      expect(await repo.lastKnownGranted(), {
        AppPermission.accessibility,
        AppPermission.overlay,
      });
    });
  });

  group('PermissionsCubit.allRequiredGranted gate', () {
    test('unknown + last-known-granted passes the gate', () async {
      final cubit = PermissionsCubit(
        _FakeRepo(
          states: {
            AppPermission.accessibility: PermissionState.unknown,
            AppPermission.overlay: PermissionState.granted,
          },
          granted: {AppPermission.accessibility},
        ),
      );
      await cubit.refresh();
      expect(cubit.allRequiredGranted, isTrue);
    });

    test('unknown with no history still gates', () async {
      final cubit = PermissionsCubit(
        _FakeRepo(
          states: {
            AppPermission.accessibility: PermissionState.unknown,
            AppPermission.overlay: PermissionState.granted,
          },
        ),
      );
      await cubit.refresh();
      expect(cubit.allRequiredGranted, isFalse);
    });

    test('a definitive denied gates regardless of history', () async {
      final cubit = PermissionsCubit(
        _FakeRepo(
          states: {
            AppPermission.accessibility: PermissionState.denied,
            AppPermission.overlay: PermissionState.granted,
          },
          granted: {AppPermission.accessibility, AppPermission.overlay},
        ),
      );
      await cubit.refresh();
      expect(cubit.allRequiredGranted, isFalse);
    });

    test('unknown is never relabelled permanently denied', () async {
      final cubit = PermissionsCubit(
        _FakeRepo(
          states: {AppPermission.accessibility: PermissionState.unknown},
        ),
      );
      await cubit.refresh();
      // Two swallowed attempts would flag a *denied* sideloaded permission —
      // an unknown reading is a channel hiccup, not a refusal.
      await cubit.request(AppPermission.accessibility);
      await cubit.request(AppPermission.accessibility);
      expect(
        cubit.state
            .firstWhere((s) => s.kind == AppPermission.accessibility)
            .state,
        PermissionState.unknown,
      );
    });
  });
}
