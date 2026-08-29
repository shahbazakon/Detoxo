/// Controls the home-screen reel counter widget (pin + refresh). The widget
/// renders natively from `ContentCounterStore` and is pushed on every count;
/// this is only the Dart control surface.
abstract interface class HomeWidgetRepository {
  /// Asks the launcher to pin the widget. Returns false when the launcher
  /// can't pin programmatically (the caller tells the user to add it by hand).
  Future<bool> pin();

  /// Forces a re-render of any pinned widgets from the native store.
  Future<void> refresh();
}
