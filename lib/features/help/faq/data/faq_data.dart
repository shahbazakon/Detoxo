import 'package:detoxo/features/help/faq/domain/entities/faq_entry.dart';

/// The full, static FAQ. Content mirrors the user-facing docs in
/// `docs/info_docs/` — keep the two in sync when either changes. Answers are
/// deliberately short and plain-language.
const List<FaqEntry> kFaqEntries = [
  // ── Setup & permissions ───────────────────────────────────────────────────
  FaqEntry(
    category: FaqCategory.setup,
    question: 'Why does Detoxo need the Accessibility permission?',
    answer:
        'It is the only way an Android app can tell that a reel or short feed '
        'is on screen inside another app. Detoxo uses it purely to detect a '
        'short-video feed and pull you out of it — nothing else.',
  ),
  FaqEntry(
    category: FaqCategory.setup,
    question: 'Which permissions are required and which are optional?',
    answer:
        'Only two are required to block: Accessibility and Display over apps. '
        'Notifications, Usage access, Unrestricted battery and Uninstall '
        'protection are recommended but optional — you can add them later.',
  ),
  FaqEntry(
    category: FaqCategory.setup,
    question: 'Why does Detoxo need "Display over apps"?',
    answer:
        'So it can draw the block screen and PIN prompt on top of other apps, '
        'and float the optional reel-counter bubble. Without it, blocking still '
        'works but the bubble stays hidden.',
  ),
  FaqEntry(
    category: FaqCategory.setup,
    question: 'I skipped a permission — can I add it later?',
    answer:
        'Yes. Open Settings → Permissions and grant it any time; Detoxo opens '
        'the right system screen and updates automatically when you return. You '
        'never have to redo onboarding.',
  ),
  FaqEntry(
    category: FaqCategory.setup,
    question: 'Why is there a permanent "Detoxo is active" notification?',
    answer:
        'Android requires an ongoing notification to keep the blocker alive in '
        'the background. It is a silent status marker, not an alert, and it '
        'makes no sound.',
  ),

  // ── Blocking & plans ──────────────────────────────────────────────────────
  FaqEntry(
    category: FaqCategory.blocking,
    question:
        "What's the difference between Block All, Conscious, One Reel and Pause?",
    answer:
        'Block All closes every reel on sight. Conscious lets you earn '
        'watch-time by staying off reels. One Reel allows a single clip, then '
        'blocks the rest. Pause suspends all blocking for a short, timed break.',
  ),
  FaqEntry(
    category: FaqCategory.blocking,
    question: 'How does Conscious earn me watch-time?',
    answer:
        'Staying off reels banks about 1 minute of allowance for every 10 '
        'minutes you abstain, up to a 10-minute cap. Watching a reel spends the '
        'bank; when it hits zero, blocking resumes until you earn more.',
  ),
  FaqEntry(
    category: FaqCategory.blocking,
    question: 'How does Detoxo actually stop me from scrolling?',
    answer:
        'By default it presses Back — the same as tapping your phone’s back '
        'button — which closes the feed. Depending on your settings it can '
        'instead close the app or lock the screen, with an optional buzz.',
  ),
  FaqEntry(
    category: FaqCategory.blocking,
    question: 'Can I still use the rest of the app?',
    answer:
        'Yes. Detoxo only steps in on the infinite reel/short feed. You can '
        'still message, search and post as normal — it blocks the bottomless '
        'part, not the whole app.',
  ),
  FaqEntry(
    category: FaqCategory.blocking,
    question: 'How do I take a quick break?',
    answer:
        'Use Pause on the home Command Center: pick 2–10 minutes and everything '
        'is allowed until the timer ends, then blocking turns itself back on '
        'automatically — no way to forget to re-enable it.',
  ),
  FaqEntry(
    category: FaqCategory.blocking,
    question: 'How do I turn blocking off entirely?',
    answer:
        'Open Settings and switch off Protection (the master switch for all '
        'detection). If you have set a PIN, Detoxo asks for it first — an '
        'intentional speed bump against an impulsive "just turn it off".',
  ),

  // ── Reel counter ──────────────────────────────────────────────────────────
  FaqEntry(
    category: FaqCategory.counter,
    question: 'Is the reel counter separate from blocking?',
    answer:
        'Completely. It runs on its own and keeps tallying even when blocking '
        'is off, paused, or the app is one you didn’t block — so you always '
        'get an honest number.',
  ),
  FaqEntry(
    category: FaqCategory.counter,
    question: 'When does a video actually count?',
    answer:
        'Once you’ve stopped on it for about a second. Flicks, half-swipes and '
        'scrolling the comments are ignored, and the same reel never counts '
        'twice — so the number reflects the reels you actually saw.',
  ),
  FaqEntry(
    category: FaqCategory.counter,
    question: 'What does the counter skip?',
    answer:
        'It counts reels and shorts but deliberately skips regular feeds, '
        'Stories and statuses — those aren’t "reels".',
  ),
  FaqEntry(
    category: FaqCategory.counter,
    question: 'Where can I see my count?',
    answer:
        'Three ways: inside the app on the Reel counter screen, on an optional '
        'floating bubble that hovers while you watch, and on an optional 2×2 '
        'home-screen widget. The bubble and widget work even when Detoxo is '
        'closed.',
  ),
  FaqEntry(
    category: FaqCategory.counter,
    question: 'Why does the floating bubble need a permission?',
    answer:
        'The bubble floats on top of other apps, which needs the Display over '
        'apps permission. It is optional — skip it and counting still works '
        'everywhere; you just won’t see the bubble.',
  ),

  // ── App & web blocker, daily limit ────────────────────────────────────────
  FaqEntry(
    category: FaqCategory.blockersLimits,
    question: 'Can I block whole apps and websites too?',
    answer:
        'Yes. Beyond reels, you can build a blocklist of distracting apps and '
        'websites, including an optional built-in adult-content list.',
  ),
  FaqEntry(
    category: FaqCategory.blockersLimits,
    question: 'How does the website blocker work?',
    answer:
        'It reads your browser’s address bar (using the same Accessibility '
        'permission) and presses Back when you land on a blocked site — no VPN '
        'required.',
  ),
  FaqEntry(
    category: FaqCategory.blockersLimits,
    question: 'What is the daily limit?',
    answer:
        'A personal per-day target for your reel time that you can set, see and '
        'reset — a self-awareness tool. For a firm cut-off, use Block All or '
        'Conscious.',
  ),

  // ── PIN & recovery ────────────────────────────────────────────────────────
  FaqEntry(
    category: FaqCategory.pin,
    question: 'Why set a PIN?',
    answer:
        'A PIN stops you from disabling Detoxo or changing protected settings '
        'on impulse. You can unlock with fingerprint or face where supported, '
        'and too many wrong tries trigger a growing cooldown.',
  ),
  FaqEntry(
    category: FaqCategory.pin,
    question: 'I forgot my PIN — how do I get back in?',
    answer:
        'There is no reset, and that is deliberate. Your PIN never leaves your '
        'phone and there is no account behind it, so any code Detoxo could '
        'accept would be a bypass anyone holding your phone could use. If you '
        'are locked out for good, uninstall Detoxo and install it again — that '
        'clears the PIN along with your settings and counts. Turn off '
        'uninstall protection first if you enabled it (Android Settings → '
        'Security → Device admin apps).',
  ),
  FaqEntry(
    category: FaqCategory.pin,
    question: 'Can I change my PIN type or turn the lock off?',
    answer:
        'Yes — open Settings → PIN settings to change the PIN type, what it '
        'guards, and biometrics, or to turn the lock off entirely. It is gated '
        'by your current PIN.',
  ),

  // ── Privacy & data ────────────────────────────────────────────────────────
  FaqEntry(
    category: FaqCategory.privacy,
    question: 'Does Detoxo read or upload my data?',
    answer:
        'Your content stays on your phone — what you watch, browse and type '
        'never leaves it. Detoxo only sends anonymous, aggregated usage and '
        'crash data to Google Firebase so we can fix bugs and improve the app.',
  ),
  FaqEntry(
    category: FaqCategory.privacy,
    question: 'What exactly is collected?',
    answer:
        'Which screens you open, when you change plan or toggle protection, how '
        'often blocking fires by app category (e.g. "YouTube", never the exact '
        'video or URL), rough reel-count totals, crashes and performance — tied '
        'to a random on-device ID, not your name or an account.',
  ),
  FaqEntry(
    category: FaqCategory.privacy,
    question: 'Are the sites or videos I block recorded?',
    answer:
        'No. When Detoxo bounces you off a site it records only that a block '
        'happened — never which site or video.',
  ),
  FaqEntry(
    category: FaqCategory.privacy,
    question: 'Are there ads, ad tracking or data selling?',
    answer:
        'None. Detoxo has no ads, no ad tracking, and never sells your data.',
  ),

  // ── Platform & iOS ────────────────────────────────────────────────────────
  FaqEntry(
    category: FaqCategory.platform,
    question: 'Does Detoxo work on iPhone / iOS?',
    answer:
        'No — Detoxo is Android-only, and this isn’t a temporary gap. The '
        'whole product relies on Android’s Accessibility Service to see a '
        'reel feed and press Back, which iOS deliberately doesn’t allow.',
  ),

  // ── Troubleshooting, battery & uninstall ──────────────────────────────────
  FaqEntry(
    category: FaqCategory.troubleshooting,
    question:
        'The Accessibility or "Display over other apps" switch won’t turn on',
    answer:
        'If Android showed "Restricted setting" or "App was denied access", '
        'that is Android protecting apps installed outside the Play Store — not '
        'a problem with Detoxo. Open Android Settings → Apps → Detoxo, tap the '
        '⋮ menu at the top right and choose "Allow restricted settings" (some '
        'phones list it at the bottom of App info instead), then come back and '
        'tap Grant. It is a one-time confirmation and unlocks every switch at '
        'once. Detoxo also offers a "Fix this" button once it notices a switch '
        'isn’t taking. Installing from the Play Store avoids this entirely.',
  ),
  FaqEntry(
    category: FaqCategory.troubleshooting,
    question: 'Will Detoxo drain my battery?',
    answer:
        'The impact is small. Detoxo only reacts briefly when a screen changes, '
        'limits how often it checks each app, and caps work per check. There is '
        'no constant polling and nothing running in the cloud.',
  ),
  FaqEntry(
    category: FaqCategory.troubleshooting,
    question: 'Blocking stopped working — what should I check?',
    answer:
        'Make sure Accessibility is still on (Settings → Permissions) and that '
        'battery is unrestricted, then reopen Detoxo so it can re-enable '
        'protection. Detoxo notices a switched-off permission and invites you '
        'to turn it back on.',
  ),
  FaqEntry(
    category: FaqCategory.troubleshooting,
    question: 'How do I uninstall Detoxo?',
    answer:
        'Like any app — unless you turned on the optional Device Admin '
        'protection. If you did, first remove Detoxo as a device administrator '
        '(from its settings, or Android’s Security settings), then uninstall '
        'normally.',
  ),
];

/// Returns entries matching [query]. An empty/blank query returns everything;
/// otherwise matches case-insensitively against question + answer. Pure and
/// dependency-free so it can be unit-tested without the cubit or widgets.
List<FaqEntry> filterFaqs(String query) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return kFaqEntries;
  return kFaqEntries.where((e) => e.matches(q)).toList(growable: false);
}
