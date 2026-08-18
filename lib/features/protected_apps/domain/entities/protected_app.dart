import 'package:equatable/equatable.dart';

/// What kind of sensitive data a protected app holds. Shown as a pill on the
/// app's card; never crosses the platform channel.
enum ProtectedAppCategory {
  banking('banking', 'Banking'),
  payments('payments', 'Payments'),
  government('government', 'Government'),
  identity('identity', 'Identity'),
  passwordManager('password_manager', 'Password Manager'),
  authentication('authentication', 'Authentication'),
  healthcare('healthcare', 'Healthcare'),
  insurance('insurance', 'Insurance'),
  investment('investment', 'Investment'),
  personalData('personal_data', 'Personal Data'),
  other('other', 'Other');

  const ProtectedAppCategory(this.wire, this.label);

  final String wire;
  final String label;

  static ProtectedAppCategory fromWire(String? wire) => values.firstWhere(
    (c) => c.wire == wire,
    orElse: () => ProtectedAppCategory.other,
  );
}

/// Where a protected-app entry came from (bundled catalog vs. user-typed).
enum ProtectedAppSource {
  catalog('catalog'),
  manual('manual');

  const ProtectedAppSource(this.wire);

  final String wire;

  static ProtectedAppSource fromWire(String? wire) => values.firstWhere(
    (s) => s.wire == wire,
    orElse: () => ProtectedAppSource.manual,
  );
}

/// Why a manual add succeeded or was refused — consumed by the add flow's
/// toast so a refused add never masquerades as success.
enum ProtectedAddResult {
  added,

  /// Not a plausible package id (see `isValidPackageName`).
  invalid,

  /// Already in the user's manual list.
  duplicate,

  /// A catalog app — protected automatically already, nothing to add.
  alreadyCovered,
}

/// An app Detoxo completely ignores while it is on screen: no counting, no
/// reading, no blocking, no analytics. Identified by [packageName] (names can
/// change; package ids can't).
class ProtectedApp extends Equatable {
  const ProtectedApp({
    required this.packageName,
    required this.appName,
    this.category = ProtectedAppCategory.other,
    this.isEnabled = true,
    this.source = ProtectedAppSource.manual,
  });

  factory ProtectedApp.fromJson(Map<String, dynamic> json) => ProtectedApp(
    packageName: json['packageName'] as String? ?? '',
    appName: json['appName'] as String? ?? '',
    category: ProtectedAppCategory.fromWire(json['category'] as String?),
    isEnabled: json['isEnabled'] as bool? ?? true,
    source: ProtectedAppSource.fromWire(json['source'] as String?),
  );

  final String packageName;
  final String appName;
  final ProtectedAppCategory category;

  /// Disabled entries stay in the list but are not pushed to the engine.
  final bool isEnabled;
  final ProtectedAppSource source;

  Map<String, dynamic> toJson() => {
    'packageName': packageName,
    'appName': appName,
    'category': category.wire,
    'isEnabled': isEnabled,
    'source': source.wire,
  };

  @override
  List<Object?> get props => [
    packageName,
    appName,
    category,
    isEnabled,
    source,
  ];
}
