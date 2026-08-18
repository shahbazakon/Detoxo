/// Normalizes and validates user-entered website domains before they become
/// blocklist entries. Accepts `example.com`, `www.example.com`,
/// `sub.example.com`, trailing-dot FQDNs and full URLs (with scheme, userinfo,
/// path, query, fragment or port); rejects empty input, spaces, scheme-only
/// text and single-label hosts.
///
/// Deliberate limits, matching what the native matcher can handle: ASCII
/// hostnames only (no IDN — paste the punycode form instead), no IPv4/IPv6
/// literals, TLD of 2–24 letters.
abstract final class DomainValidator {
  // One or more dot-separated labels (letters/digits/hyphens, not edge hyphens)
  // followed by a 2–24 character TLD.
  static final RegExp _host = RegExp(
    r'^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,24}$',
  );

  static const invalidMessage = 'Enter a valid domain like youtube.com';

  static String duplicateMessage(String host) => '$host is already blocked';

  /// The single validate+dedupe rule shared by the add/edit sheet and the
  /// cubit. Returns the normalized host, or an error message.
  static ({String? host, String? error}) check(
    String input,
    Iterable<String> existingPatterns, {
    String? ignoring,
  }) {
    final host = normalize(input);
    if (host == null) return (host: null, error: invalidMessage);
    if (host != ignoring && existingPatterns.contains(host)) {
      return (host: null, error: duplicateMessage(host));
    }
    return (host: host, error: null);
  }

  /// Returns the cleaned host (scheme/userinfo/`www.`/path/query/port stripped,
  /// lower cased) or `null` when the input is not a valid domain.
  static String? normalize(String input) {
    var s = input.trim().toLowerCase();
    if (s.isEmpty) return null;
    s = s.replaceFirst(RegExp('^[a-z][a-z0-9+.-]*://'), ''); // scheme
    s = s.split('/').first; // path
    s = s.split('?').first.split('#').first; // query / fragment
    // Userinfo before the port split, or `user:pass@host` would yield `user`.
    s = s.substring(s.lastIndexOf('@') + 1);
    s = s.split(':').first; // port
    s = s.replaceFirst(RegExp(r'^www\.'), '');
    s = s.replaceFirst(RegExp(r'\.$'), ''); // trailing-dot FQDN form
    if (s.isEmpty || s.contains(' ') || !s.contains('.')) return null;
    return _host.hasMatch(s) ? s : null;
  }
}
