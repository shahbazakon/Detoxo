import 'dart:async';

import 'package:detoxo/features/blocking/blocking.dart';
import 'package:detoxo/features/content_counter/content_counter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockRepo extends Mock implements BlockScreenRepository {}

void main() {
  setUpAll(() {
    registerFallbackValue(const BlockScreenStyle.defaults());
    registerFallbackValue(BlockScreenPayload.preview());
  });

  late _MockRepo repo;

  setUp(() {
    repo = _MockRepo();
    when(() => repo.setStyle(any())).thenAnswer((_) async {});
  });

  test('hydrates from the repository', () async {
    const persisted = BlockScreenStyle(enabled: false, theme: WidgetTheme.dark);
    when(repo.style).thenAnswer((_) async => persisted);
    final cubit = BlockScreenStyleCubit(repo);
    await Future<void>.delayed(Duration.zero);
    expect(cubit.state, persisted);
    await cubit.close();
  });

  test('a burst of edits persists once, after the debounce', () async {
    when(repo.style).thenAnswer((_) async => const BlockScreenStyle.defaults());
    final cubit = BlockScreenStyleCubit(repo);
    await Future<void>.delayed(Duration.zero);

    cubit
      ..setBackground(WidgetBackground.solid)
      ..setTheme(WidgetTheme.light)
      ..setShowCount(show: false);
    expect(cubit.state.background, WidgetBackground.solid);
    expect(cubit.state.theme, WidgetTheme.light);
    expect(cubit.state.showCount, isFalse);
    verifyNever(() => repo.setStyle(any()));

    await Future<void>.delayed(const Duration(milliseconds: 200));
    verify(() => repo.setStyle(cubit.state)).called(1);
    await cubit.close();
  });

  test('an edit that beats the hydrate wins', () async {
    final hydrate = Completer<BlockScreenStyle>();
    when(repo.style).thenAnswer((_) => hydrate.future);
    final cubit = BlockScreenStyleCubit(repo)..setEnabled(enabled: false);
    hydrate.complete(const BlockScreenStyle(accentByUsage: true));
    await Future<void>.delayed(Duration.zero);

    expect(cubit.state.enabled, isFalse);
    expect(cubit.state.accentByUsage, isFalse); // not snapped back
    await cubit.close();
  });

  test('switching the wall off pushes enabled=false', () async {
    when(repo.style).thenAnswer((_) async => const BlockScreenStyle.defaults());
    final cubit = BlockScreenStyleCubit(repo);
    await Future<void>.delayed(Duration.zero);

    cubit.setEnabled(enabled: false);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    final pushed =
        verify(() => repo.setStyle(captureAny())).captured.single
            as BlockScreenStyle;
    expect(pushed.enabled, isFalse);
    expect(pushed.toWire()['enabled'], isFalse);
    await cubit.close();
  });

  test('a failed hydrate keeps the defaults and never throws', () async {
    when(repo.style).thenThrow(Exception('channel down'));
    final cubit = BlockScreenStyleCubit(repo);
    await Future<void>.delayed(Duration.zero);
    expect(cubit.state, const BlockScreenStyle.defaults());
    await cubit.close();
  });
}
