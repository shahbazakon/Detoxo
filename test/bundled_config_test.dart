import 'package:detoxo/features/blocking/shared/data/repositories/config_repository_impl.dart';
import 'package:flutter_test/flutter_test.dart';

/// The bundled platforms config is the one load-bearing asset decode that is
/// deliberately NOT wrapped in a try/catch: a malformed shipped asset is a
/// build defect, and swallowing it would silently turn every blocklist into a
/// no-op. This test is the guard — it parses the REAL bundled asset through
/// the real repository, so a bad edit to `assets/config/` fails here at build
/// time instead of crashing every blocklist call site on devices.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'the shipped platforms config parses and yields block targets',
    () async {
      final repo = ConfigRepositoryImpl();

      final targets = await repo.loadBlockTargets();

      expect(targets, isNotEmpty);
      // Every target must carry the fields the engine keys on.
      for (final t in targets) {
        expect(t.platformId, isNotEmpty);
      }
    },
  );
}
