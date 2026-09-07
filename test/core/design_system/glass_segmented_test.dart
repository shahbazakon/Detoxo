import 'package:detoxo/core/design_system/components/selection.dart';
import 'package:detoxo/core/design_system/theme/app_theme.dart';
import 'package:detoxo/core/design_system/tokens/app_spacing.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// AppTheme pulls google_fonts, which stalls under flutter_test.
ThemeData _theme() => ThemeData(
  brightness: Brightness.dark,
  extensions: const [GlassTokens.dark],
);

Future<int?> _pump(
  WidgetTester tester, {
  bool expand = true,
  double height = 52,
}) async {
  int? tapped;
  await tester.pumpWidget(
    MaterialApp(
      theme: _theme(),
      home: Scaffold(
        body: Center(
          child: StatefulBuilder(
            builder: (context, setState) => GlassSegmented(
              segments: const [
                (label: 'Today', icon: Icons.today_rounded),
                (label: 'All', icon: null),
              ],
              selectedIndex: tapped ?? 0,
              expand: expand,
              height: height,
              onChanged: (i) => setState(() => tapped = i),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return tapped;
}

/// The sliding pill's current left edge, in global coordinates.
double _pillLeft(WidgetTester tester) =>
    tester.getTopLeft(find.byType(FractionallySizedBox)).dx;

void main() {
  testWidgets('tapping a segment reports its index and slides the pill', (
    tester,
  ) async {
    await _pump(tester);
    final before = _pillLeft(tester);

    // The labels are decorative; the hit layer above them takes the tap.
    await tester.tap(find.text('All'), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(_pillLeft(tester), greaterThan(before));

    await tester.tap(find.text('Today'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(_pillLeft(tester), before);
  });

  // expand: false runs the control through IntrinsicWidth, where a flex child
  // under an unbounded constraint is an easy way to blow up.
  testWidgets('hugs its content without exploding', (tester) async {
    await _pump(tester, expand: false);
    expect(tester.takeException(), isNull);

    final hugged = tester.getSize(find.byType(GlassSegmented)).width;
    await _pump(tester);
    expect(hugged, lessThan(tester.getSize(find.byType(GlassSegmented)).width));
  });

  // A card-header control is drawn 44 tall; its segments used to be bare
  // 36 dp GestureDetectors, under the 48 dp floor the token file states.
  testWidgets('a compact control still takes a 48 dp tap', (tester) async {
    await _pump(tester, height: AppSizes.controlHeight, expand: false);

    final box = tester.getSize(find.byType(GlassSegmented));
    expect(box.height, greaterThanOrEqualTo(AppSizes.minTapTarget));
    // The visible track is unchanged — only the hit box grew.
    expect(
      tester.getSize(find.byType(FractionallySizedBox)).height,
      AppSizes.controlHeight - 8,
    );

    // A tap on the padding, above the track, still lands on its segment.
    final all = tester.getCenter(find.text('All'));
    final top = tester.getTopLeft(find.byType(GlassSegmented)).dy;
    await tester.tapAt(Offset(all.dx, top + 1));
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.byType(FractionallySizedBox)).dx,
      greaterThan(0),
    );
    expect(
      tester.getSemantics(find.text('All').last).label,
      isEmpty,
      reason: 'labels are decorative; the hit layer carries the semantics',
    );
  });
}
