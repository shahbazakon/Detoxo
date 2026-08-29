import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/core/di/injector.dart';
import 'package:detoxo/core/navigation/routes.dart';
import 'package:detoxo/features/additional_feature/showcase_view/showcase_view.dart';
import 'package:detoxo/features/dashboard/presentation/widgets/blocker_tile.dart';
import 'package:detoxo/features/dashboard/presentation/widgets/rules_card.dart';
import 'package:detoxo/features/limits/limits.dart';
import 'package:detoxo/gen/assets.gen.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// The dashboard's blocker pair — App Blocker and Web Blocker side by side —
/// with the full-width Rules card beneath them.
///
/// Owns the live entry counts. Both blocker cubits are screen-scoped (created
/// inside their own `BlocProvider`s), so there is nothing to watch from here;
/// the section reads the repositories through [sl] instead and refreshes when
/// the user pops back from either screen. (Rules have an app-wide cubit, so
/// [RulesCard] watches it directly.)
class BlockerSection extends StatefulWidget {
  const BlockerSection({super.key});

  @override
  State<BlockerSection> createState() => _BlockerSectionState();
}

class _BlockerSectionState extends State<BlockerSection> {
  int _apps = 0;
  int _sites = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final apps = await sl<AppBlockRepository>().load();
    final sites = await sl<WebBlockRepository>().load();
    if (!mounted) return;
    setState(() {
      _apps = apps.where((e) => e.enabled).length;
      _sites = sites.where((e) => e.enabled).length;
    });
  }

  /// Opens a blocker screen and re-reads the counts once it pops, so the
  /// captions are never stale after an edit.
  Future<void> _open(String route) async {
    await context.push(route);
    await _load();
  }

  static String _caption(int n, String noun) =>
      n == 0 ? 'Not set up' : '$n $noun${n == 1 ? '' : 's'} blocked';

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _tiles(context),
        const SizedBox(height: AppSpacing.sm),
        // EVO-051: above the rules card, and absent entirely when nothing is
        // allowed — it exists to be noticed exactly when something is.
        const ActiveUnblocksCard(),
        const RulesCard(),
      ],
    );
  }

  Widget _tiles(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: showcaseTarget(
            step: featureShowcaseSteps[5],
            index: 5,
            child: BlockerTile(
              image: Assets.images.illustration.appBlock.path,
              title: 'App Blocker',
              caption: _caption(_apps, 'app'),
              active: _apps > 0,
              onTap: () => _open(Routes.appBlock),
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: showcaseTarget(
            step: featureShowcaseSteps[6],
            index: 6,
            child: BlockerTile(
              image: Assets.images.illustration.webBlock.path,
              title: 'Web Blocker',
              caption: _caption(_sites, 'site'),
              active: _sites > 0,
              accent: Theme.of(context).colorScheme.secondary,
              levitateDelay: const Duration(milliseconds: 900),
              onTap: () => _open(Routes.webBlock),
            ),
          ),
        ),
      ],
    );
  }
}
