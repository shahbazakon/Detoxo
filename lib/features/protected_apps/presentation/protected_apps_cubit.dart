import 'package:detoxo/core/utils/package_name.dart';
import 'package:detoxo/features/blocking/shared/domain/repositories/blocking_repositories.dart';
import 'package:detoxo/features/protected_apps/domain/entities/protected_app.dart';
import 'package:detoxo/features/protected_apps/domain/entities/protected_app_catalog.dart';
import 'package:detoxo/features/protected_apps/domain/protected_apps_boot.dart';
import 'package:detoxo/features/protected_apps/domain/repositories/protected_apps_repository.dart';
import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// Manages the user's own protected-app additions. Catalog apps are protected
/// automatically and permanently — they are never stored, toggled or removed;
/// every push to the engine is `catalog ∪ manual` (see [protectedPackagesFor]).
class ProtectedAppsCubit extends Cubit<ProtectedAppsState> {
  ProtectedAppsCubit(this._repo, this._engine, this._config)
    : super(const ProtectedAppsState());

  final ProtectedAppsRepository _repo;
  final EngineRepository _engine;
  final ConfigRepository _config;

  /// Loads (and reloads — the error state's Retry re-enters here). Whatever
  /// the repo returned is always emitted, even when a later await fails: the
  /// screen must never show an empty list over non-empty storage, or one add
  /// would overwrite the user's saved protections.
  Future<void> load() async {
    emit(
      ProtectedAppsState(
        apps: state.apps,
        installed: state.installed,
        monitoredPackages: state.monitoredPackages,
      ),
    );
    var apps = state.apps;
    try {
      apps = await _repo.load();
      final installed = await _engine.installedPackages();
      // Blocking-catalog packages, for the add-time PIN gate: protecting a
      // monitored app is a self-bypass of blocking, so it costs the same PIN
      // as turning blocking off.
      final targets = await _config.loadBlockTargets();
      emit(
        ProtectedAppsState(
          isLoading: false,
          apps: apps,
          installed: installed,
          monitoredPackages: {for (final t in targets) t.packageName},
        ),
      );
      // Re-sync native on entry so it matches whatever is persisted (cheap:
      // native skips an unchanged set entirely).
      await _push();
    } on Object catch (e) {
      emit(
        ProtectedAppsState(
          isLoading: false,
          apps: apps,
          installed: state.installed,
          monitoredPackages: state.monitoredPackages,
          error: e.toString(),
        ),
      );
    }
  }

  /// Whether adding [packageName] must pass the settings PIN first (it is an
  /// app Detoxo can block, so protecting it bypasses blocking). Fails closed:
  /// an empty monitored set means the load hasn't completed or failed, so
  /// every add costs the PIN rather than silently skipping the gate.
  bool needsPinToAdd(String packageName) =>
      state.monitoredPackages.isEmpty ||
      state.monitoredPackages.contains(packageName.trim());

  /// Adds a manual protection, or says why it can't — the caller's toast must
  /// tell the truth, so a refusal is never silent.
  Future<ProtectedAddResult> addManual(
    String packageName,
    String appName,
  ) async {
    final pkg = packageName.trim();
    if (!isValidPackageName(pkg)) return ProtectedAddResult.invalid;
    // Catalog packages are already protected automatically — nothing to add.
    if (ProtectedAppCatalog.byPackage(pkg) != null) {
      return ProtectedAddResult.alreadyCovered;
    }
    if (state.contains(pkg)) return ProtectedAddResult.duplicate;
    final name = appName.trim();
    await _commit([
      ...state.apps,
      ProtectedApp(packageName: pkg, appName: name.isEmpty ? pkg : name),
    ]);
    return ProtectedAddResult.added;
  }

  Future<void> remove(String packageName) =>
      _commit(state.apps.where((a) => a.packageName != packageName).toList());

  Future<void> _commit(List<ProtectedApp> apps) async {
    emit(state.copyWith(apps: apps));
    await _repo.save(apps);
    await _push();
  }

  /// Package names only — names/categories never cross the channel.
  Future<void> _push() =>
      _engine.pushProtectedApps(protectedPackagesFor(state.apps));
}

class ProtectedAppsState extends Equatable {
  const ProtectedAppsState({
    this.isLoading = true,
    this.apps = const [],
    this.installed,
    this.monitoredPackages = const {},
    this.error,
  });

  final bool isLoading;

  /// The user's manual additions only — catalog apps are implicit.
  final List<ProtectedApp> apps;

  /// Installed launchable packages, or `null` when unknown (off-Android /
  /// channel error) — unknown treats everything as installed.
  final Set<String>? installed;

  /// Packages of the blocking catalog (Instagram, YouTube…) — adding one of
  /// these to the protected list is PIN-gated.
  final Set<String> monitoredPackages;
  final String? error;

  bool contains(String packageName) =>
      apps.any((a) => a.packageName == packageName);

  bool isInstalled(String packageName) =>
      installed?.contains(packageName) ?? true;

  /// Catalog apps shown in the read-only "Auto-protected" section: installed
  /// ones (all of them when install state is unknown). Protection itself
  /// covers the whole catalog regardless.
  List<ProtectedApp> get autoProtected => [
    for (final app in ProtectedAppCatalog.apps)
      if (isInstalled(app.packageName)) app,
  ];

  ProtectedAppsState copyWith({
    bool? isLoading,
    List<ProtectedApp>? apps,
    Set<String>? installed,
    Set<String>? monitoredPackages,
    String? error,
  }) => ProtectedAppsState(
    isLoading: isLoading ?? this.isLoading,
    apps: apps ?? this.apps,
    installed: installed ?? this.installed,
    monitoredPackages: monitoredPackages ?? this.monitoredPackages,
    error: error ?? this.error,
  );

  @override
  List<Object?> get props => [
    isLoading,
    apps,
    installed,
    monitoredPackages,
    error,
  ];
}
