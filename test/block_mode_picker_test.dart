import 'dart:ui' show Tristate;

import 'package:detoxo/core/design_system/theme/app_theme.dart';
import 'package:detoxo/features/blocking/blocking.dart' show BlockingMode;
import 'package:detoxo/features/settings/presentation/widgets/block_mode_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// AppTheme pulls google_fonts, which stalls under flutter_test — the picker
// only needs GlassTokens plus a ColorScheme (the ModeSelector precedent).
final _theme = ThemeData(
  brightness: Brightness.dark,
  extensions: const [GlassTokens.dark],
);

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: _theme,
      home: MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: Scaffold(body: child),
      ),
    ),
  );
}

void main() {
  testWidgets('offers the four modes and announces the selected one', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _pump(
      tester,
      BlockModeOptions(selected: BlockingMode.blockScreen, onSelect: (_) {}),
    );

    for (final label in [
      'Press back',
      'Block screen',
      'Close the app',
      'Lock app',
    ]) {
      expect(find.text(label), findsOneWidget);
    }
    // Exactly one row is selected, and the glyph is not the only signal.
    final selected = tester
        .widgetList<OptionTile>(find.byType(OptionTile))
        .where((t) => t.selected)
        .toList();
    expect(selected.map((t) => t.title), ['Block screen']);
    expect(
      tester.getSemantics(find.text('Block screen')).flagsCollection.isSelected,
      Tristate.isTrue,
    );
    expect(
      tester.getSemantics(find.text('Press back')).flagsCollection.isSelected,
      isNot(Tristate.isTrue),
    );
    handle.dispose();
  });

  testWidgets('tapping a row reports that mode', (tester) async {
    BlockingMode? picked;
    await _pump(
      tester,
      BlockModeOptions(
        selected: BlockingMode.pressBack,
        onSelect: (m) => picked = m,
      ),
    );
    await tester.tap(find.text('Close the app'));
    expect(picked, BlockingMode.killApp);
  });

  testWidgets(
    'the entry tile names the mode and warns only without the grant',
    (tester) async {
      var granted = 0;
      await _pump(
        tester,
        BlockModeTile(
          mode: BlockingMode.blockScreen,
          needsOverlay: true,
          onTap: () {},
          onGrant: () => granted++,
        ),
      );
      expect(find.text('Block screen'), findsOneWidget);
      expect(find.text('Needs “Display over other apps”'), findsOneWidget);
      await tester.tap(find.text('Needs “Display over other apps”'));
      expect(granted, 1);

      await _pump(
        tester,
        BlockModeTile(
          mode: BlockingMode.blockScreen,
          needsOverlay: false,
          onTap: () {},
          onGrant: () {},
        ),
      );
      expect(find.text('Needs “Display over other apps”'), findsNothing);
    },
  );
}
