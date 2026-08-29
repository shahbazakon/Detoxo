import 'package:detoxo/features/catalog/domain/entities/app_behavior.dart';
import 'package:equatable/equatable.dart';

/// One product inside a category — the unit that owns package ids and domains.
/// "Instagram" is a service; `com.instagram.android`, `com.instagram.lite` and
/// `instagram.com` are how it shows up on the device.
class CategoryService extends Equatable {
  const CategoryService({
    required this.id,
    required this.displayName,
    this.androidPackages = const [],
    this.domains = const [],
  });

  final String id;
  final String displayName;

  /// Android application ids (case preserved — `com.Slack` is real).
  final List<String> androidPackages;

  /// Registrable domains (plus genuine cross-domain aliases like `youtu.be`).
  /// Subdomains resolve to the same service via the catalog's suffix walk.
  final List<String> domains;

  @override
  List<Object?> get props => [id, displayName, androidPackages, domains];
}

/// A group of services that share one [behavior]. Categories are what a rule
/// targets ("block distracting apps") and what stats roll up by.
class AppCategory extends Equatable {
  const AppCategory({
    required this.id,
    required this.displayName,
    required this.behavior,
    this.services = const [],
  });

  final String id;
  final String displayName;
  final AppBehavior behavior;
  final List<CategoryService> services;

  @override
  List<Object?> get props => [id, displayName, behavior, services];
}
