import 'package:detoxo/core/utils/app_logger.dart';
import 'package:detoxo/features/catalog/domain/app_category_seed.dart';
import 'package:detoxo/features/catalog/domain/entities/app_behavior.dart';
import 'package:detoxo/features/catalog/domain/entities/app_category.dart';

/// The app / website taxonomy as fast lookups. Built once from a list of
/// [AppCategory]s into six indices; every query after that is a map read.
///
/// Hosts are matched by walking their suffixes down to — but never including —
/// the bare TLD: `m.facebook.com` → `facebook.com` → stop. (The native adult
/// list deliberately walks one step further so a bare `porn` line blocks every
/// `*.porn` host; that is a different rule for a different job — do not
/// "share" the two walks.)
class Catalog {
  const Catalog._({
    required this.categories,
    required this._packageToCategory,
    required this._domainToCategory,
    required this._packageToService,
    required this._domainToService,
    required this._categoryToPackages,
  });

  /// Builds the indices. On a duplicate package or domain the last writer wins;
  /// a collision that changes the category is logged because it means the seed
  /// disagrees with itself.
  factory Catalog.build(List<AppCategory> categories) {
    final p2c = <String, AppCategory>{};
    final d2c = <String, AppCategory>{};
    final p2s = <String, CategoryService>{};
    final d2s = <String, CategoryService>{};
    final c2p = <String, List<String>>{};
    for (final category in categories) {
      final packages = <String>[];
      for (final service in category.services) {
        for (final pkg in service.androidPackages) {
          _put(p2c, pkg, category);
          p2s[pkg] = service;
          packages.add(pkg);
        }
        for (final domain in service.domains) {
          final host = normalizeHost(domain);
          _put(d2c, host, category);
          d2s[host] = service;
        }
      }
      c2p[category.id] = List.unmodifiable(packages);
    }
    return Catalog._(
      categories: List.unmodifiable(categories),
      packageToCategory: p2c,
      domainToCategory: d2c,
      packageToService: p2s,
      domainToService: d2s,
      categoryToPackages: c2p,
    );
  }

  /// No categories: every lookup is null / neutral / empty.
  static const Catalog empty = Catalog._(
    categories: [],
    packageToCategory: {},
    domainToCategory: {},
    packageToService: {},
    domainToService: {},
    categoryToPackages: {},
  );

  /// The shipped taxonomy, built on first use and cached for the process.
  // ponytail: bundled static taxonomy; an app released after our last build is
  // neutral until we ship a new seed. Upgrade path = the ConfigRepository
  // remote-refresh seam, versioned like configVersion.
  static final Catalog bundled = Catalog.build(AppCategorySeed.categories);

  final List<AppCategory> categories;
  final Map<String, AppCategory> _packageToCategory;
  final Map<String, AppCategory> _domainToCategory;
  final Map<String, CategoryService> _packageToService;
  final Map<String, CategoryService> _domainToService;
  final Map<String, List<String>> _categoryToPackages;

  AppCategory? categoryForPackage(String packageName) =>
      _packageToCategory[packageName];

  /// [AppBehavior.neutral] for anything the catalog does not know.
  AppBehavior behaviorForPackage(String packageName) =>
      categoryForPackage(packageName)?.behavior ?? AppBehavior.neutral;

  CategoryService? serviceForPackage(String packageName) =>
      _packageToService[packageName];

  /// The domains that serve the same content as [packageName] (drives "block
  /// sites for blocked apps"). Empty for an unknown package.
  List<String> domainsForPackage(String packageName) =>
      _packageToService[packageName]?.domains ?? const [];

  /// First catalog hit walking [host]'s suffixes; null for an unknown host or
  /// a bare TLD.
  AppCategory? categoryForHost(String host) {
    for (final suffix in suffixesOf(normalizeHost(host))) {
      final hit = _domainToCategory[suffix];
      if (hit != null) return hit;
    }
    return null;
  }

  CategoryService? serviceForHost(String host) {
    for (final suffix in suffixesOf(normalizeHost(host))) {
      final hit = _domainToService[suffix];
      if (hit != null) return hit;
    }
    return null;
  }

  /// Every package in [categoryId], in seed order. Empty for an unknown id.
  ///
  /// Indexed, not scanned: the rules resolver calls this once per category per
  /// rule on every resume, mutation and boundary — at the 50-rule cap that was
  /// 500 walks of the whole seed, and 500 fresh lists, per resolve.
  List<String> packagesIn(String categoryId) =>
      _categoryToPackages[categoryId] ?? const [];

  /// Every package whose category carries [behavior], in seed order. Drives
  /// the soft nudge's watch list (M7) — derived from the taxonomy rather than
  /// curated, so there is no second list to keep in step.
  ///
  /// Scanned, not indexed, unlike [packagesIn]: this is called once per config
  /// push (boot, resume, a settings change), not per rule per resolve.
  List<String> packagesWithBehavior(AppBehavior behavior) => [
    for (final category in categories)
      if (category.behavior == behavior) ...packagesIn(category.id),
  ];

  /// The ids of every category carrying [behavior], in seed order — the rule
  /// editor's "All distracting" quick-pick. Same owner as
  /// [packagesWithBehavior], so a second copy of "what counts as distracting"
  /// cannot drift from the first.
  List<String> categoriesWithBehavior(AppBehavior behavior) => [
    for (final category in categories)
      if (category.behavior == behavior) category.id,
  ];

  /// Lower-cases, trims, and strips the trailing-dot FQDN form and a leading
  /// `www.` — the same shape every domain in the seed is stored in.
  static String normalizeHost(String host) {
    var h = host.trim().toLowerCase();
    if (h.endsWith('.')) h = h.substring(0, h.length - 1);
    if (h.startsWith('www.')) h = h.substring(4);
    return h;
  }

  /// `m.facebook.com` → `m.facebook.com`, `facebook.com`. Never the bare TLD.
  static Iterable<String> suffixesOf(String host) sync* {
    final parts = host.split('.');
    for (var i = 0; i <= parts.length - 2; i++) {
      yield parts.sublist(i).join('.');
    }
  }

  static void _put(Map<String, AppCategory> index, String key, AppCategory c) {
    final previous = index[key];
    if (previous != null && previous.id != c.id) {
      AppLogger.w('catalog: "$key" moved from ${previous.id} to ${c.id}');
    }
    index[key] = c;
  }
}
