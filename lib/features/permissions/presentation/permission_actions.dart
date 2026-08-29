import 'package:detoxo/core/design_system/design_system.dart';
import 'package:detoxo/features/permissions/domain/entities/permission_status.dart';
import 'package:detoxo/features/permissions/presentation/permissions_cubit.dart';
import 'package:detoxo/features/permissions/presentation/widgets/restricted_settings_sheet.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

/// The single entry point for granting a permission from anywhere in the app —
/// the funnel, the settings sheet and the dashboard card all route through here
/// so the disclosure and the recovery flow can't drift between them.
///
/// Order matters: if Android's restricted-settings gate is already swallowing
/// the grant, another trip to the system toggle just repeats the dead end, so
/// the walkthrough wins over a fresh request.
///
/// Returns **false** when the user turned the request down before it was made —
/// declining a prominent disclosure, or being routed to the restricted-settings
/// walkthrough instead. It is *not* a grant result: the settings-based
/// permissions hand off to a system screen that returns nothing, so `true` only
/// means "the request was actually issued". Callers that care about the grant
/// re-read [PermissionsCubit] afterwards; callers that don't may ignore this.
Future<bool> requestPermission(BuildContext context, AppPermission kind) async {
  final cubit = context.read<PermissionsCubit>();
  final status = cubit.state.firstWhere(
    (s) => s.kind == kind,
    orElse: () => PermissionStatus(kind: kind),
  );

  if (status.blockedByRestrictedSettings) {
    await RestrictedSettingsSheet.show(context);
    return false;
  }

  final disclosure = _disclosureFor(kind);
  if (disclosure != null) {
    final accepted = await _confirmDisclosure(context, disclosure);
    if (!accepted) return false;
  }

  await cubit.request(kind);
  return true;
}

/// The two grants whose scope is wider than their name suggests, and which Play
/// policy requires a prominent in-app disclosure for *before* the system screen.
/// Everything else in the funnel is self-explanatory and goes straight through.
({String title, IconData icon, String message})? _disclosureFor(
  AppPermission kind,
) => switch (kind) {
  // Wording mirrors `accessibility_service_description` in
  // `android/app/src/main/res/values/strings.xml` so the in-app and OS-level
  // text agree — keep the two in sync.
  AppPermission.accessibility => (
    title: 'How Detoxo uses Accessibility',
    icon: Icons.accessibility_new,
    message:
        'Detoxo uses the Accessibility Service to detect short-form video '
        '(reels, shorts) in your apps and block it so you can stay focused.\n\n'
        'It reads on-screen content only to find and block distracting feeds. '
        'That check happens on your device, in the moment, and is thrown away '
        'immediately — Detoxo does not collect, store or transmit your screen '
        'content, messages or keystrokes.\n\n'
        'The next screen is Android’s own. Find Detoxo in the list and turn '
        'it on.',
  ),
  // This grant is broader than it looks and the user deserves to know that
  // before granting it: Android hands a notification listener every
  // notification on the device, not only the ones Detoxo cares about.
  AppPermission.notificationListener => (
    title: 'How Detoxo uses Notification access',
    icon: Icons.notifications_off,
    message:
        'Android gives this permission access to every notification on your '
        'device — there is no way to ask for only some apps.\n\n'
        'Detoxo reads two things: which app sent the notification, and '
        'whether the app marked it as a message, call or alarm. If it came '
        'from an app you have locked or scheduled, and it is not one of '
        'those, it is dismissed so it can’t pull you back.\n\n'
        'Messages and calls always come through, even from a blocked app. '
        'Nothing else is read — not the title, the text, the sender or the '
        'images — and nothing is stored, logged or sent anywhere.\n\n'
        'Apps on your Protected list are never touched. You can turn this off '
        'any time in Settings, and Detoxo stops receiving notifications '
        'entirely.\n\n'
        'The next screen is Android’s own. Find Detoxo in the list and turn '
        'it on.',
  ),
  _ => null,
};

Future<bool> _confirmDisclosure(
  BuildContext context,
  ({String title, IconData icon, String message}) disclosure,
) async {
  final accepted = await AppDialog.show<bool>(
    context: context,
    title: disclosure.title,
    icon: disclosure.icon,
    message: disclosure.message,
    actions: [
      GhostButton(
        label: 'Not now',
        onPressed: () => Navigator.of(context).pop(false),
      ),
      PrimaryButton(
        label: 'Continue',
        onPressed: () => Navigator.of(context).pop(true),
      ),
    ],
  );
  return accepted ?? false;
}
