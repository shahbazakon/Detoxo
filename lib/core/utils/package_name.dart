/// Android application-id shape: two-plus dot-separated segments, each
/// starting with a letter, `[A-Za-z0-9_]` inside. Case is preserved and
/// allowed — `com.Slack` is a real package id — so never lowercase input
/// before matching against event packages.
final RegExp _packageNameRe = RegExp(
  r'^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$',
);

/// True when [s] is a plausible Android package id. Used by the add flows so
/// garbage ("my bank", "instagram") is rejected instead of persisted as an
/// entry that can never match a real foreground package.
bool isValidPackageName(String s) =>
    s.length <= 255 && _packageNameRe.hasMatch(s);
