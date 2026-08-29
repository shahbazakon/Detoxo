import 'package:detoxo/features/blocking/shared/domain/repositories/blocking_repositories.dart';
import 'package:detoxo/features/catalog/catalog.dart';

/// The apps the soft nudge times: everything the catalog calls `distracting`.
///
/// Derived, never curated — the nudge deliberately has no list of its own, so
/// an app added to the shipped taxonomy is nudged the day it ships and there is
/// no second list to drift. Note these apps are NOT blocked by being here; the
/// nudge only counts how long one has been open.
List<String> nudgePackages() =>
    Catalog.bundled.packagesWithBehavior(AppBehavior.distracting);

/// Pushes the soft-nudge config to the engine. Called at boot and on resume
/// (via `syncEngineBlocklists`) so native always matches Dart, and again by the
/// settings cubit whenever one of the three nudge fields changes.
Future<void> syncNudgeConfig(
  SettingsRepository settings,
  EngineRepository engine,
) async {
  await engine.pushNudgeConfig(await settings.load(), nudgePackages());
}
