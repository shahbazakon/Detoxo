import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The 18+ list is authored in `tool/web_blocker/blocked_websites.json` and
/// shipped as the native asset `adult_domains.txt.gz` (compiled by
/// `bash tool/dev.sh adultlist`). This is the guard that the two never drift —
/// nothing else compares them, and a stale asset silently under-blocks.
///
/// The `blocked()` helper below MIRRORS `WebBlockEngine.matchHost`'s suffix
/// walk rather than calling it, so the semantic assertions here pin the SHAPE
/// of the data, not the engine. Changing the native walk will not fail them —
/// `android/app/src/test/kotlin/.../engine/` is where engine behaviour is
/// pinned.
void main() {
  final source =
      jsonDecode(
            File('tool/web_blocker/blocked_websites.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  final domains = (source['domains'] as List).cast<String>();
  final tlds = (source['tlds'] as List).cast<String>();
  final allow = (source['allow'] as List).cast<String>();
  final shipped = const LineSplitter()
      .convert(
        utf8.decode(
          gzip.decode(
            File(
              'android/app/src/main/assets/adult_domains.txt.gz',
            ).readAsBytesSync(),
          ),
        ),
      )
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty && !l.startsWith('#'))
      .toSet();

  /// Mirror of the native walk: the host, then each parent label, then the TLD.
  bool blocked(String host) {
    var h = host;
    while (true) {
      if (shipped.contains(h)) return true;
      final dot = h.indexOf('.');
      if (dot < 0) return false;
      h = h.substring(dot + 1);
    }
  }

  test('the shipped asset is exactly the compiled source', () {
    expect(
      shipped,
      {...domains, ...tlds},
      reason: 'source and asset drifted — run `bash tool/dev.sh adultlist`',
    );
  });

  test('entries are unique lowercase registrable hosts or bare TLDs', () {
    final host = RegExp(r'^(?:[a-z0-9-]+\.)*[a-z]{2,24}$');
    expect(domains.toSet().length, domains.length);
    for (final d in [...domains, ...tlds]) {
      expect(d, matches(host), reason: '$d is not a plain lowercase host');
      expect(d.startsWith('www.'), isFalse, reason: '$d: drop the www.');
    }
    // Every entry blocks itself and all of its subdomains.
    expect(blocked(domains.first), isTrue);
    expect(blocked('sub.${domains.first}'), isTrue);
  });

  test('the ICANN adult TLDs are blocked wholesale', () {
    expect(tlds, containsAll(['adult', 'porn', 'sex', 'xxx']));
    expect(blocked('anything.tik.porn'), isTrue);
    expect(blocked('example.xxx'), isTrue);
    // A TLD entry only ever matches as the LAST label.
    expect(blocked('sussex.ac.uk'), isFalse);
  });

  test('allow-listed hosts are never covered', () {
    for (final h in allow) {
      expect(blocked(h), isFalse, reason: '$h must never be blocked');
      expect(blocked('www.$h'), isFalse);
    }
  });

  test('scraped hosts are covered, so every page under them is', () {
    // From the original blocked_websites.json scrape (url == redirect_url).
    expect(blocked('theporndude.com'), isTrue);
    expect(blocked('de.theporndude.com'), isTrue);
    expect(blocked('pdude.link'), isTrue);
  });

  test(
    'the Protection screen says "200+ known adult sites" — keep it true',
    () {
      expect(domains.length, greaterThanOrEqualTo(200));
    },
  );
}
