import 'package:detoxo/core/design_system/components/permission_card.dart';
import 'package:detoxo/core/platform/platform_capabilities.dart';
import 'package:detoxo/core/theme/app_theme.dart';
import 'package:detoxo/features/blocking/engine/presentation/service_cubit.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/engine_event.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
import 'package:detoxo/features/dashboard/presentation/widgets/protection_status_card.dart';
import 'package:detoxo/features/permissions/presentation/permissions_cubit.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockService extends Mock implements ServiceCubit {}

class _MockPermissions extends Mock implements PermissionsCubit {}

/// Pins the `unknown`-state rendering (EVO-014): a status read that didn't
/// answer must render neutral — never as denied, and never as "Protection
/// off". Before this, unknown collapsed into the red denied/scare states on
/// every cold start or flaky channel read.
void main() {
  group('PermissionCard', () {
    Future<void> pump(
      WidgetTester tester, {
      required bool granted,
      bool unknown = false,
    }) => tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: Scaffold(
          body: PermissionCard(
            icon: Icons.security,
            title: 'Accessibility',
            why: 'Detects reels on screen.',
            granted: granted,
            unknown: unknown,
            isRequired: true,
            onGrant: () {},
          ),
        ),
      ),
    );

    testWidgets('granted renders the check, no action button', (tester) async {
      await pump(tester, granted: true);
      expect(find.text('Granted'), findsOneWidget);
      expect(find.text('Grant'), findsNothing);
      expect(find.text('Checking…'), findsNothing);
    });

    testWidgets('unknown renders neutral "Checking…", not a denied row', (
      tester,
    ) async {
      await pump(tester, granted: false, unknown: true);
      expect(find.text('Checking…'), findsOneWidget);
      expect(find.text('Grant'), findsNothing);
      expect(find.text('Granted'), findsNothing);
    });

    testWidgets('denied renders the Grant action', (tester) async {
      await pump(tester, granted: false);
      expect(find.text('Grant'), findsOneWidget);
      expect(find.text('Checking…'), findsNothing);
    });
  });

  group('ProtectionStatusCard', () {
    late _MockService service;
    late _MockPermissions permissions;

    setUp(() {
      PlatformCapabilities.debugForceAndroid = true;
      service = _MockService();
      permissions = _MockPermissions();
      when(() => service.stream).thenAnswer((_) => const Stream.empty());
      when(() => permissions.stream).thenAnswer((_) => const Stream.empty());
      when(() => permissions.state).thenReturn(const []);
    });

    tearDown(() => PlatformCapabilities.debugForceAndroid = null);

    Future<void> pump(WidgetTester tester, ServiceStatus status) {
      when(() => service.state).thenReturn(ServiceSnapshot(status: status));
      return tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: MultiBlocProvider(
              providers: [
                BlocProvider<ServiceCubit>.value(value: service),
                BlocProvider<PermissionsCubit>.value(value: permissions),
              ],
              child: const ProtectionStatusCard(),
            ),
          ),
        ),
      );
    }

    testWidgets('unknown renders neutral "Checking…", never the scare card', (
      tester,
    ) async {
      await pump(tester, ServiceStatus.unknown);
      expect(find.text('Checking…'), findsOneWidget);
      expect(find.text('Protection off'), findsNothing);
      expect(find.text('Enable now'), findsNothing);
    });

    testWidgets('stopped still renders the real scare card', (tester) async {
      await pump(tester, ServiceStatus.stopped);
      expect(find.text('Protection off'), findsOneWidget);
      expect(find.text('Checking…'), findsNothing);
    });

    testWidgets('running renders the active row', (tester) async {
      await pump(tester, ServiceStatus.running);
      // The pulsing shield (flutter_animate) arms a zero-duration timer in
      // initState; give it one frame so teardown sees no pending timers.
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('Protection Status'), findsOneWidget);
      expect(find.text('Active & Optimized'), findsOneWidget);
    });
  });
}
