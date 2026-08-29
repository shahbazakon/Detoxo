import 'dart:convert';

import 'package:detoxo/core/services/firebase/firebase_services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pins the one place an error object crosses the network boundary.
///
/// `FormatException.toString()` embeds a window of its **source string**. Five
/// repositories log a decode failure as `AppLogger.e(msg, e)`, and the blob
/// being decoded is the user's own data — the protected-apps list above all,
/// whose entire promise is that it never leaves the device
/// (`docs/code_docs/24-protected-apps.md` §6). Without redaction a corrupt
/// document uploads package names to Crashlytics.
void main() {
  /// The real shape: a `usage_daily` document truncated mid-write.
  FormatException decodeFailureOf(String source) {
    try {
      jsonDecode(source);
      fail('expected the source to be undecodable');
    } on FormatException catch (e) {
      return e;
    }
  }

  group('FirebaseServices.offDevice', () {
    test('strips the source window from a decode failure', () {
      final e = decodeFailureOf(
        '{"days":{"03-09-2026":{"topApps":['
        '{"package":"com.sbi.lotusintouch","ms":900000},'
        '{"package":"com.phonepe.app","ms":2460000}]}} <<TRUNCATED',
      );

      // The raw exception leaks: the window is ~78 characters ending at the
      // offset, so it carries whatever was being decoded there — here a UPI
      // package from the protected-apps catalog.
      expect(e.toString(), contains('com.phonepe.app'));

      final sent = FirebaseServices.offDevice(e).toString();
      expect(sent, isNot(contains('com.phonepe.app')));
      expect(sent, isNot(contains('lotusintouch')));
      expect(sent, isNot(contains('package')));
      expect(sent, isNot(contains('{')));
    });

    test('keeps enough to debug a corrupt document', () {
      final sent = FirebaseServices.offDevice(
        decodeFailureOf('{not json'),
      ).toString();

      expect(sent, contains('FormatException'));
      expect(sent, contains('Unexpected character'));
      expect(sent, contains('offset'));
    });

    test('a hand-built FormatException carrying a source is scrubbed too', () {
      const e = FormatException(
        'Bad value',
        'pin=1234 host=bank.example.com',
        4,
      );

      final sent = FirebaseServices.offDevice(e).toString();
      expect(sent, isNot(contains('1234')));
      expect(sent, isNot(contains('bank.example.com')));
      expect(sent, contains('Bad value'));
    });

    test('an offset-less FormatException does not render a null offset', () {
      const e = FormatException('Bad value', 'secret-source');

      expect(
        FirebaseServices.offDevice(e).toString(),
        'FormatException: Bad value',
      );
    });

    test('every other error passes through untouched', () {
      final state = StateError('engine down');
      final argument = ArgumentError('end must be after start');

      // The leak is specific to exceptions that carry their input; redacting
      // everything would cost real diagnostics for nothing.
      expect(FirebaseServices.offDevice(state), same(state));
      expect(FirebaseServices.offDevice(argument), same(argument));
    });

    test('null passes through so the bridge can fall back to the message', () {
      expect(FirebaseServices.offDevice(null), isNull);
    });
  });
}
