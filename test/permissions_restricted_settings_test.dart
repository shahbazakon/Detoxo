import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
import 'package:detoxo/features/permissions/domain/entities/permission_status.dart';
import 'package:detoxo/features/permissions/domain/repositories/permission_repository.dart';
import 'package:detoxo/features/permissions/presentation/permissions_cubit.dart';
import 'package:flutter_test/flutter_test.dart';

/// A repository whose grants never land — the signature of Android's
/// restricted-settings / ECM gate swallowing the toggle.
class _FakeRepo implements PermissionRepository {
  _FakeRepo({this.outsidePlay = true});

  final bool outsidePlay;
  int openedAppSettings = 0;

  @override
  Future<bool> installedOutsidePlay() async => outsidePlay;

  @override
  Future<Set<AppPermission>> lastKnownGranted() async => const {};

  @override
  Future<void> openAppSettings() async => openedAppSettings++;

  @override
  Future<void> request(AppPermission permission) async {}

  @override
  Future<PermissionStatus> status(AppPermission permission) async =>
      PermissionStatus(kind: permission, state: PermissionState.denied);

  @override
  Future<List<PermissionStatus>> statuses() async => [
    for (final p in AppPermission.values) await status(p),
  ];
}

PermissionStatus _of(PermissionsCubit cubit, AppPermission kind) =>
    cubit.state.firstWhere((s) => s.kind == kind);

void main() {
  group('restricted-settings detection', () {
    test('sideloaded: flags only after a second swallowed attempt', () async {
      final cubit = PermissionsCubit(_FakeRepo());
      await cubit.refresh();

      expect(
        _of(cubit, AppPermission.accessibility).blockedByRestrictedSettings,
        isFalse,
      );

      // One failure is noise — users back out, or tap Grant just to look.
      await cubit.request(AppPermission.accessibility);
      expect(
        _of(cubit, AppPermission.accessibility).blockedByRestrictedSettings,
        isFalse,
      );

      await cubit.request(AppPermission.accessibility);
      expect(
        _of(cubit, AppPermission.accessibility).blockedByRestrictedSettings,
        isTrue,
      );
    });

    test('only gate-able permissions are flagged', () async {
      final cubit = PermissionsCubit(_FakeRepo());
      await cubit.refresh();
      await cubit.request(AppPermission.usageAccess);
      await cubit.request(AppPermission.usageAccess);

      // Usage access isn't behind the gate; two failures mean something else.
      expect(
        _of(cubit, AppPermission.usageAccess).blockedByRestrictedSettings,
        isFalse,
      );
    });

    test('a Play install is never flagged', () async {
      final cubit = PermissionsCubit(_FakeRepo(outsidePlay: false));
      await cubit.refresh();
      await cubit.request(AppPermission.accessibility);
      await cubit.request(AppPermission.accessibility);

      expect(cubit.state.every((s) => !s.blockedByRestrictedSettings), isTrue);
    });

    test(
      'opening app settings clears the flag so cards read Grant again',
      () async {
        final repo = _FakeRepo();
        final cubit = PermissionsCubit(repo);
        await cubit.refresh();
        await cubit.request(AppPermission.accessibility);
        await cubit.request(AppPermission.accessibility);
        expect(
          _of(cubit, AppPermission.accessibility).blockedByRestrictedSettings,
          isTrue,
        );

        await cubit.openAppSettings();
        await cubit.refresh();

        expect(repo.openedAppSettings, 1);
        expect(
          _of(cubit, AppPermission.accessibility).blockedByRestrictedSettings,
          isFalse,
        );
      },
    );
  });
}
