import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/core/platform_channels/installed_app.dart';
import 'package:detoxo/core/widgets/common_widgets.dart';
import 'package:flutter/material.dart';

export 'package:detoxo/core/platform_channels/installed_app.dart';

/// Multi-select installed-app picker in a [GlassBottomSheet]: searchable list
/// of the device's launchable apps (icon + name + package), with already-added
/// apps shown dimmed and unselectable, and a manual name+package form as the
/// fallback for apps the system hides (work profiles, engine unavailable, iOS).
///
/// Returns the picked apps — a manual entry returns a single icon-less
/// [InstalledApp] — or null when dismissed.
///
/// [unavailable] maps a package name to the pill label explaining why it can't
/// be picked again ('Added', 'Protected', 'Auto-protected'…). Enforced in the
/// list and in the manual form — an unavailable package can't be confirmed.
///
/// [refreshApps] (optional) enables the refresh button next to the search
/// field — the escape hatch for apps installed after the cached scan.
Future<List<InstalledApp>?> showAppPickerSheet(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  required Future<List<InstalledApp>?> Function() loadApps,
  Future<List<InstalledApp>?> Function()? refreshApps,
  Map<String, String> unavailable = const {},
}) {
  return GlassBottomSheet.show<List<InstalledApp>>(
    context: context,
    title: title,
    child: SizedBox(
      // Bounded height: the sheet's Flexible clamps this under the keyboard.
      height: MediaQuery.sizeOf(context).height * 0.72,
      child: _AppPickerBody(
        confirmLabel: confirmLabel,
        loadApps: loadApps,
        refreshApps: refreshApps,
        unavailable: unavailable,
      ),
    ),
  );
}

class _AppPickerBody extends StatefulWidget {
  const _AppPickerBody({
    required this.confirmLabel,
    required this.loadApps,
    required this.refreshApps,
    required this.unavailable,
  });

  final String confirmLabel;
  final Future<List<InstalledApp>?> Function() loadApps;
  final Future<List<InstalledApp>?> Function()? refreshApps;
  final Map<String, String> unavailable;

  @override
  State<_AppPickerBody> createState() => _AppPickerBodyState();
}

class _AppPickerBodyState extends State<_AppPickerBody> {
  List<InstalledApp>? _apps;
  bool _loading = true;
  bool _manual = false;
  String _query = '';
  final Set<String> _selected = {};

  final _nameController = TextEditingController();
  final _pkgController = TextEditingController();

  @override
  void initState() {
    super.initState();
    // _loading already starts true; no setState before the first build.
    _run(widget.loadApps, initial: true);
  }

  void _run(
    Future<List<InstalledApp>?> Function() scan, {
    bool initial = false,
  }) {
    if (!initial) setState(() => _loading = true);
    scan().then((apps) {
      if (!mounted) return;
      setState(() {
        // A failed rescan keeps whatever was already shown.
        _apps = apps ?? _apps;
        _loading = false;
      });
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    _pkgController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _manual ? _manualForm(context) : _pickerList(context);
  }

  // ── Picker list mode ──────────────────────────────────────────────────────

  Widget _pickerList(BuildContext context) {
    final refresh = widget.refreshApps;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: AppSearchField(
                hintText: 'Search apps',
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
            if (refresh != null)
              IconButton(
                icon: const Icon(Icons.refresh),
                tooltip: 'Refresh app list',
                onPressed: _loading ? null : () => _run(refresh),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Expanded(child: _content(context)),
        const SizedBox(height: AppSpacing.sm),
        GhostButton(
          label: "Can't find it? Add manually",
          onPressed: () => setState(() => _manual = true),
        ),
        const SizedBox(height: AppSpacing.xs),
        PrimaryButton(
          expand: true,
          label: _selected.isEmpty
              ? widget.confirmLabel
              : '${widget.confirmLabel} (${_selected.length})',
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.of(context).pop([
                  for (final app in _apps!)
                    if (_selected.contains(app.packageName)) app,
                ]),
        ),
      ],
    );
  }

  Widget _content(BuildContext context) {
    if (_loading) return const LoadingState(message: 'Loading your apps…');

    final apps = _apps;
    if (apps == null) {
      return const EmptyState(
        icon: Icons.error_outline,
        title: 'Couldn’t read your apps',
        subtitle: 'You can still add one manually below.',
      );
    }

    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? apps
        : apps
              .where(
                (a) =>
                    a.appName.toLowerCase().contains(q) ||
                    a.packageName.toLowerCase().contains(q),
              )
              .toList();
    if (filtered.isEmpty) {
      return const EmptyState(icon: Icons.search_off, title: 'No matches');
    }

    return ListView.separated(
      itemCount: filtered.length,
      separatorBuilder: (_, _) => const SizedBox(height: AppSpacing.sm),
      itemBuilder: (context, i) => _tile(context, filtered[i]),
    );
  }

  Widget _tile(BuildContext context, InstalledApp app) {
    final reason = widget.unavailable[app.packageName];
    if (reason != null) {
      return GlassListTile(
        leading: AppIconAvatar(
          iconUrl: '',
          iconBytes: app.icon,
          appName: app.appName,
          dimmed: true,
        ),
        title: app.appName,
        subtitle: app.packageName,
        trailing: Pill(label: reason),
      );
    }

    final selected = _selected.contains(app.packageName);
    return GlassListTile(
      selected: selected,
      leading: AppIconAvatar(
        iconUrl: '',
        iconBytes: app.icon,
        appName: app.appName,
      ),
      title: app.appName,
      subtitle: app.packageName,
      trailing: Icon(
        selected ? Icons.check_circle_rounded : Icons.circle_outlined,
        color: selected ? Theme.of(context).colorScheme.primary : null,
      ),
      onTap: () => setState(() {
        if (selected) {
          _selected.remove(app.packageName);
        } else {
          _selected.add(app.packageName);
        }
      }),
    );
  }

  // ── Manual entry mode (package-visibility / no-engine escape hatch) ───────

  Widget _manualForm(BuildContext context) {
    final pkg = _pkgController.text.trim();
    final reason = widget.unavailable[pkg];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              children: [
                TextField(
                  controller: _nameController,
                  decoration: const InputDecoration(labelText: 'App name'),
                ),
                const SizedBox(height: AppSpacing.sm),
                TextField(
                  controller: _pkgController,
                  // Package ids, like URLs, must survive the keyboard: no
                  // autocapitalize/autocorrect (matches the web-blocker field).
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Package (com.example.app)',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                if (reason != null) ...[
                  const SizedBox(height: AppSpacing.sm),
                  InlineHint(
                    icon: Icons.lock_outline,
                    text: "Already $reason — this app can't be added here.",
                  ),
                ],
              ],
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        GhostButton(
          label: 'Back to app list',
          onPressed: () => setState(() => _manual = false),
        ),
        const SizedBox(height: AppSpacing.xs),
        PrimaryButton(
          expand: true,
          label: widget.confirmLabel,
          onPressed: pkg.isEmpty || reason != null
              ? null
              : () {
                  final name = _nameController.text.trim();
                  // Selections made in list mode ride along — switching to
                  // manual entry must not silently discard them.
                  Navigator.of(context).pop([
                    for (final app in _apps ?? const <InstalledApp>[])
                      if (_selected.contains(app.packageName)) app,
                    if (!_selected.contains(pkg))
                      InstalledApp(
                        packageName: pkg,
                        appName: name.isEmpty ? pkg : name,
                      ),
                  ]);
                },
        ),
      ],
    );
  }
}
