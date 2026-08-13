import 'package:detoxo/core/design_system/theme/app_theme.dart';
import 'package:detoxo/features/access_protection/domain/entities/pin_config.dart';
import 'package:detoxo/features/access_protection/domain/pin_hasher.dart';
import 'package:detoxo/features/access_protection/domain/repositories/pin_repository.dart';
import 'package:detoxo/features/access_protection/presentation/pin_cubit.dart';
import 'package:detoxo/features/access_protection/presentation/pin_setup_screen.dart';
import 'package:detoxo/features/blocking/shared/domain/entities/enums.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

class _FakePinRepo implements PinRepository {
  PinConfig _stored = const PinConfig();
  @override
  Future<PinConfig> load() async => _stored;
  @override
  Future<void> save(PinConfig config) async => _stored = config;
  @override
  Future<void> setSecureScreen({required bool enabled}) async {}
  @override
  Future<int> lastScreenOffMillis() async => 0;
}

PinConfig _configuredCustom() {
  final salt = PinHasher.newSalt();
  return PinConfig(
    type: PinType.custom,
    secretHash: PinHasher.hash(salt, '1234'),
    salt: salt,
    secretLength: 4,
    scopes: const {PinScope.app, PinScope.settings},
  );
}

Widget _host(PinCubit cubit) => MaterialApp(
  theme: AppTheme.dark(),
  home: BlocProvider.value(
    value: cubit,
    child: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => BlocProvider.value(
                  value: cubit,
                  child: const PinSetupScreen(),
                ),
              ),
            ),
            child: const Text('open setup'),
          ),
        ),
      ),
    ),
  ),
);

// GlassScaffold runs an infinite ambient animation, so pumpAndSettle never
// converges — settle by pumping a few fixed frames instead.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Save PIN does not crash', (tester) async {
    final cubit = PinCubit(_FakePinRepo());
    await tester.pumpWidget(_host(cubit));
    await tester.tap(find.text('open setup'));
    await settle(tester);

    await tester.enterText(find.widgetWithText(TextField, 'PIN'), '1234');
    await tester.enterText(
      find.widgetWithText(TextField, 'Confirm PIN'),
      '1234',
    );
    await settle(tester);

    // The Save button sits below the fold in the lazy ListView — scroll to it.
    final save = find.text('Save PIN');
    await tester.scrollUntilVisible(
      save,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await settle(tester);
    await tester.tap(save);
    await settle(tester);
    expect(tester.takeException(), isNull, reason: 'Save PIN');
    expect(cubit.state.isConfigured, isTrue);
  });

  testWidgets('Turn off via None + confirm does not crash', (tester) async {
    final repo = _FakePinRepo();
    await repo.save(_configuredCustom());
    final cubit = PinCubit(repo)..emit(_configuredCustom());

    await tester.pumpWidget(_host(cubit));
    await tester.tap(find.text('open setup'));
    await settle(tester);

    // Open the PIN-type sheet and pick "None".
    await tester.tap(find.text('PIN type').last);
    await settle(tester);
    await tester.tap(find.text('None — no lock'));
    await settle(tester);
    expect(tester.takeException(), isNull, reason: 'after picking None');

    // Save now turns the lock off → confirm dialog.
    await tester.tap(find.text('Turn off PIN lock'));
    await settle(tester);
    expect(tester.takeException(), isNull, reason: 'opening confirm dialog');
    expect(find.text('Turn off PIN lock?'), findsOneWidget);

    await tester.tap(find.text('Turn off'));
    await settle(tester);
    expect(tester.takeException(), isNull, reason: 'confirming turn-off');
    expect(cubit.state.isConfigured, isFalse);
  });
}
