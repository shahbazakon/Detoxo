import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/core/navigation/routes.dart';
import 'package:detoxo/core/platform_channels/installed_app.dart';
import 'package:detoxo/features/limits/limits.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

/// A per-app row that is also the way to act on it: avatar, label, a trailing
/// figure and a bar relative to the busiest app, opening the rule editor
/// pre-filled with a daily limit for that package.
///
/// EVO-033's rule, the one row behind the Activity tab's **By app** segments
/// — reels, blocks and screen time. Detoxo's whole
/// argument is that a chart the next morning is too late
/// (`docs/info_docs/01-product-overview.md`, "The problem"); seeing "1h 10m"
/// or "31 blocks" against an app is exactly the moment a limit gets set, so
/// the row opens the editor for that app instead of leaving the user to find
/// Rules and rebuild the thought. Never a silent save — the editor is where
/// they pick the hours (the EVO-031 preset rule).
class AppLimitRow extends StatelessWidget {
  const AppLimitRow({
    required this.package,
    required this.trailing,
    required this.fraction,
    this.installed,
    this.name,
    this.iconUrl = '',
    this.spokenTrailing,
    super.key,
  });

  final String package;

  /// Null when the app is not in the engine's installed list (uninstalled
  /// since the figure was recorded, or the lookup failed) — the row still
  /// renders, labelled by [name] or the package name.
  final InstalledApp? installed;

  /// A label to fall back on before the package name (the reel counter
  /// carries its own display names).
  final String? name;

  /// Icon asset for [AppIconAvatar] when there are no installed-app bytes.
  final String iconUrl;

  /// The figure on the right: "1h 10m", "31".
  final String trailing;

  /// What a screen reader says for [trailing] when the visible form is a bare
  /// number ("31 blocks"). Defaults to [trailing].
  final String? spokenTrailing;

  /// Bar length relative to the busiest row, 0–1.
  final double fraction;

  String get _label {
    // Trimmed: a launcher entry whose label resource is blank returns a
    // non-empty string of spaces, which passed `isNotEmpty` into a blank row.
    final installedName = installed?.appName.trim() ?? '';
    if (installedName.isNotEmpty) return installedName;
    final own = name?.trim() ?? '';
    return own.isNotEmpty ? own : package;
  }

  Future<void> _limitThisApp(BuildContext context) {
    return context.push(
      Routes.ruleEditor,
      extra: RuleEditorArgs(
        kind: RuleKind.timeLimit,
        rule: Rule(
          id: const Uuid().v4(),
          name: 'Limit $_label',
          kind: RuleKind.timeLimit,
          createdAtMs: DateTime.now().millisecondsSinceEpoch,
          // thresholdMs stays at its 0 default on purpose: the editor makes
          // the user choose a budget rather than accepting one Detoxo invented.
          selection: RuleSelection(apps: [package]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final label = _label;
    // `AppPressable`, like every other custom tappable in the app: the press
    // scale, the haptic the segmented control above already gives, a focus
    // ring for switch access, and one `button` node carrying the sentence.
    // `ExcludeSemantics` sits *inside* the tappable, not around it: excluding
    // at the top would swallow the tap action and leave a screen reader
    // announcing a button it cannot activate.
    return AppPressable(
      semanticLabel: '$label, ${spokenTrailing ?? trailing}. Set a daily limit',
      pressedScale: 0.99,
      onTap: () => _limitThisApp(context),
      child: Padding(
        // `xs`, not `xxs`: the 34 dp avatar plus 8 dp each side clears the
        // 48 dp floor (`AppSizes.minTapTarget`) across the whole row.
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: ExcludeSemantics(child: _row(context, label)),
      ),
    );
  }

  Widget _row(BuildContext context, String label) {
    final text = Theme.of(context).textTheme;
    return Row(
      children: [
        AppIconAvatar(
          iconUrl: iconUrl,
          iconBytes: installed?.icon,
          appName: label,
          borderRadius: AppRadius.brSm,
        ),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Text(
                    trailing,
                    style: text.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.xxs),
                  Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: context.glass.onGlassMuted,
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.xxs),
              ProgressBar(progress: fraction, animate: true),
            ],
          ),
        ),
      ],
    );
  }
}
