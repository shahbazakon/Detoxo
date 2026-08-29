/// The answer to a usage query, keeping "we were not allowed to look" and "the
/// engine did not answer" distinct from a genuinely quiet window. A screen must
/// never render `0 m` for either of the non-granted cases (EVO-014).
///
/// Same shape as `core/utils/result.dart`'s `Result`: consume with a Dart 3
/// `switch`.
sealed class UsageQueryResult<T> {
  const UsageQueryResult();

  bool get isGranted => this is UsageGranted<T>;

  /// The data if granted, otherwise null.
  T? get dataOrNull => switch (this) {
    UsageGranted<T>(:final data) => data,
    UsageDenied<T>() || UsageUnavailable<T>() => null,
  };
}

/// Usage Access is granted and the OS answered.
final class UsageGranted<T> extends UsageQueryResult<T> {
  const UsageGranted(this.data);
  final T data;
}

/// Usage Access is not granted — an optional permission in the funnel.
final class UsageDenied<T> extends UsageQueryResult<T> {
  const UsageDenied();
}

/// No native engine (iOS / tests) or the query itself failed.
final class UsageUnavailable<T> extends UsageQueryResult<T> {
  const UsageUnavailable();
}
