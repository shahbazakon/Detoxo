import 'package:detoxo/app/engine_sync.dart';
import 'package:flutter_test/flutter_test.dart';

/// `guardedSync` is the whole reason a failing bootstrap leg cannot stop app
/// start: `runBootstrap` wraps every phase in it, and `main()` wraps the
/// Firebase handshake in it. Before that, a throw anywhere in the splash's
/// inline sequence left the user on the spinner with force-stop as the only way
/// out.
///
/// The phase-2/phase-3 ordering (targets loaded exactly once on a first run) is
/// deliberately NOT tested here. `runBootstrap` takes a `BuildContext` and
/// reads seven cubits, so the only honest test is an integration one — and a
/// unit test that re-implements the predicate would pin a copy, staying green
/// while the real bootstrap regressed. It is on the device checklist instead.
void main() {
  group('guardedSync — one failing leg never stops app start', () {
    test('a throwing step is swallowed, not rethrown', () {
      expect(
        guardedSync('boom', Future<void>.error(StateError('native gone'))),
        completes,
      );
    });

    test('a succeeding step still runs', () async {
      var ran = false;
      await guardedSync('ok', Future<void>(() => ran = true));
      expect(ran, isTrue);
    });

    test('one failure does not abort its siblings', () async {
      // The shape `runBootstrap`'s phase 1 relies on: three legs in a
      // `Future.wait`, where a dead channel on one must not take the other two
      // — and therefore the gate decision — down with it.
      final done = <String>[];
      await Future.wait([
        guardedSync('a', Future<void>(() => done.add('a'))),
        guardedSync('b', Future<void>.error(StateError('x'))),
        guardedSync('c', Future<void>(() => done.add('c'))),
      ]);
      expect(done, ['a', 'c']);
    });

    test('a synchronous throw inside the future is caught too', () async {
      await expectLater(
        guardedSync(
          'sync-throw',
          Future<void>.sync(() => throw StateError('!')),
        ),
        completes,
      );
    });
  });
}
