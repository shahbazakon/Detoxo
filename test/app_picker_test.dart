import 'package:detoxo/core/design_system/theme/app_theme.dart';
import 'package:detoxo/core/widgets/app_picker_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// AppTheme pulls google_fonts, which stalls under flutter_test — the sheet only
// needs GlassTokens plus a ColorScheme, so build a minimal theme here.
ThemeData _theme() => ThemeData(
  brightness: Brightness.dark,
  extensions: const [GlassTokens.dark],
);

const _apps = [
  InstalledApp(packageName: 'com.a.alpha', appName: 'Alpha'),
  InstalledApp(packageName: 'com.b.bravo', appName: 'Bravo'),
  InstalledApp(packageName: 'com.c.charlie', appName: 'Charlie'),
];

void main() {
  List<InstalledApp>? result;

  Future<void> pumpAndOpen(
    WidgetTester tester, {
    Future<List<InstalledApp>?> Function()? loadApps,
    Future<List<InstalledApp>?> Function()? refreshApps,
    Map<String, String> unavailable = const {},
  }) async {
    result = null;
    await tester.pumpWidget(
      MaterialApp(
        theme: _theme(),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  result = await showAppPickerSheet(
                    context,
                    title: 'Pick apps',
                    confirmLabel: 'Add',
                    loadApps: loadApps ?? () async => _apps,
                    refreshApps: refreshApps,
                    unavailable: unavailable,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('renders every app with name and package', (tester) async {
    await pumpAndOpen(tester);
    for (final app in _apps) {
      expect(find.text(app.appName), findsOneWidget);
      expect(find.text(app.packageName), findsOneWidget);
    }
  });

  testWidgets('multi-select returns exactly the picked apps', (tester) async {
    await pumpAndOpen(tester);
    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Charlie'));
    await tester.pumpAndSettle();
    expect(find.text('Add (2)'), findsOneWidget);
    await tester.tap(find.text('Add (2)'));
    await tester.pumpAndSettle();
    expect(result, [_apps[0], _apps[2]]);
  });

  testWidgets('selection state is exposed to screen readers', (tester) async {
    final semantics = tester.ensureSemantics();
    await pumpAndOpen(tester);
    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(find.text('Alpha')),
      isSemantics(isSelected: true, isButton: true),
    );
    expect(
      tester.getSemantics(find.text('Bravo')),
      isSemantics(isSelected: false, isButton: true),
    );
    semantics.dispose();
  });

  testWidgets('manual confirm keeps list selections', (tester) async {
    await pumpAndOpen(tester);
    await tester.tap(find.text('Alpha'));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Can't find it? Add manually"));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Package (com.example.app)'),
      'com.typed.app',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(result, const [
      InstalledApp(packageName: 'com.a.alpha', appName: 'Alpha'),
      InstalledApp(packageName: 'com.typed.app', appName: 'com.typed.app'),
    ]);
  });

  testWidgets('refresh button rescans and updates the list', (tester) async {
    var refreshed = 0;
    await pumpAndOpen(
      tester,
      refreshApps: () async {
        refreshed++;
        return const [
          InstalledApp(packageName: 'com.new.app', appName: 'Newcomer'),
        ];
      },
    );
    expect(find.text('Alpha'), findsOneWidget);
    await tester.tap(find.byTooltip('Refresh app list'));
    await tester.pumpAndSettle();
    expect(refreshed, 1);
    expect(find.text('Newcomer'), findsOneWidget);
    expect(find.text('Alpha'), findsNothing);
  });

  testWidgets('unavailable app shows its reason and cannot be selected', (
    tester,
  ) async {
    await pumpAndOpen(tester, unavailable: {'com.b.bravo': 'Added'});
    expect(find.text('Added'), findsOneWidget);
    await tester.tap(find.text('Bravo'));
    await tester.pumpAndSettle();
    // Still nothing selected: the confirm button keeps its bare label.
    expect(find.text('Add (1)'), findsNothing);
  });

  testWidgets('search filters by name and by package', (tester) async {
    await pumpAndOpen(tester);
    await tester.enterText(find.byType(TextField).first, 'brav');
    await tester.pumpAndSettle();
    expect(find.text('Alpha'), findsNothing);
    expect(find.text('Bravo'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'com.c');
    await tester.pumpAndSettle();
    expect(find.text('Charlie'), findsOneWidget);
    expect(find.text('Bravo'), findsNothing);

    await tester.enterText(find.byType(TextField).first, 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('No matches'), findsOneWidget);
  });

  testWidgets('manual entry returns a typed app, name defaulting to package', (
    tester,
  ) async {
    await pumpAndOpen(tester);
    await tester.tap(find.text("Can't find it? Add manually"));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Package (com.example.app)'),
      'com.typed.app',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(result, const [
      InstalledApp(packageName: 'com.typed.app', appName: 'com.typed.app'),
    ]);
  });

  testWidgets('manual entry refuses an unavailable package', (tester) async {
    await pumpAndOpen(tester, unavailable: {'com.b.bravo': 'Auto-protected'});
    await tester.tap(find.text("Can't find it? Add manually"));
    await tester.pumpAndSettle();
    final pkgField = find.widgetWithText(
      TextField,
      'Package (com.example.app)',
    );
    await tester.enterText(pkgField, 'com.b.bravo');
    await tester.pumpAndSettle();
    expect(
      find.text("Already Auto-protected — this app can't be added here."),
      findsOneWidget,
    );
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(result, isNull); // Confirm disabled: the sheet did not pop.

    // A free package still confirms.
    await tester.enterText(pkgField, 'com.free.app');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(result, const [
      InstalledApp(packageName: 'com.free.app', appName: 'com.free.app'),
    ]);
  });

  testWidgets('engine unavailable shows the error state, manual still works', (
    tester,
  ) async {
    await pumpAndOpen(tester, loadApps: () async => null);
    expect(find.text('Couldn’t read your apps'), findsOneWidget);
    await tester.tap(find.text("Can't find it? Add manually"));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Package (com.example.app)'),
      'com.hidden.app',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'App name'),
      'Hidden',
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(result, const [
      InstalledApp(packageName: 'com.hidden.app', appName: 'Hidden'),
    ]);
  });
}
