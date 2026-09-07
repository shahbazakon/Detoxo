import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/features/limits/limits.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

/// The card derives its sentence from the clock and `overridesLeft` at build
/// time, so it must repaint on the resync emit that moves `overridesLeft` on an
/// unchanged ledger — a ledger-only `buildWhen` used to filter exactly that one.

/// A cubit whose state the test sets directly; nothing else on it is called.
class _StubUnblock extends Cubit<UnblockState> implements UnblockCubit {
  _StubUnblock(super.state);

  void push(UnblockState next) => emit(next);

  @override
  dynamic noSuchMethod(Invocation i) =>
      throw UnsupportedError('${i.memberName} not used by the card');
}

void main() {
  testWidgets('a resync that moves overridesLeft on the same ledger repaints', (
    tester,
  ) async {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final ledger = [
      BypassEntry(
        kind: BypassKind.override,
        atMs: nowMs - 3600000,
        reason: OverrideReason.family,
      ),
    ];
    UnblockState state(int left) => UnblockState(
      loaded: true,
      ledgerLoaded: true,
      ledger: ledger,
      overridesLeft: left,
    );
    final cubit = _StubUnblock(state(1));
    addTearDown(cubit.close);

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(extensions: const [GlassTokens.dark]),
        home: Scaffold(
          body: BlocProvider<UnblockCubit>.value(
            value: cubit,
            child: const OverrideHistoryCard(),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('1 override this period'), findsOneWidget);
    expect(find.text('Family — 1 left'), findsOneWidget);

    // The period rolled over and the timer resync re-derived the quota: the
    // ledger is the same list, only `overridesLeft` moved.
    cubit.push(state(2));
    // One pump delivers the stream event, the next paints the rebuild.
    await tester.pump();
    await tester.pump();
    expect(find.text('Family — 2 left'), findsOneWidget);
    expect(find.text('Family — 1 left'), findsNothing);
  });
}
