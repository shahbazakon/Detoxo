# Permissions Explained

Detoxo asks for a handful of Android permissions during setup. That can feel like a lot, so this page explains — in plain language — exactly what each one does, why Detoxo needs it, and what it does **not** do.

The short version, up front:

- Everything Detoxo does to detect and count Reels & Shorts happens **on your phone**. What you scroll, watch, browse, or type is never uploaded.
- Its blocking is **offline-first** (no custom server). The only thing Detoxo sends is **anonymous, aggregated diagnostics** to Google Firebase — crashes, performance, and which features get used — never your browsing or content. See *Your privacy, plainly* below.
- Only **two** permissions are actually required to block. The rest are optional and make Detoxo more reliable — you can skip them and add them later.

---

## Two required, the rest recommended

During the "Set up protection" screen you'll see permissions split into two groups.

| Permission (label you'll see) | Group | What it unlocks |
|---|---|---|
| **Accessibility** | Required to block | Detecting and blocking Reels & Shorts |
| **Display over apps** | Required to block | Showing the block / PIN screen on top of other apps |
| **Notifications** | Recommended | A heads-up if protection ever stops |
| **Usage access** | Recommended | App usage limits |
| **Unrestricted battery** | Recommended | Keeping the blocker alive in the background |
| **Uninstall protection** (Device admin) | Recommended | Making Detoxo harder to remove in a moment of weakness |

Until both required permissions are granted, the **Continue** button stays disabled. Once they're on, you're protected — the recommended ones just make things smoother and can be turned on anytime from **Settings**.

Each permission is granted on Android's own system screen. Detoxo simply opens the right screen for you; you flip the switch and come back, and the setup list updates automatically to show it's done.

---

## Accessibility — required

**What you'll see:** "Accessibility" — *Lets Detoxo detect and block reels & shorts.*

**Why it's needed.** Accessibility is the only way an app on Android can tell what's on screen in *another* app. Detoxo uses it to notice when a Reels/Shorts/infinite-feed surface opens in Instagram, YouTube, and the other apps you've chosen to block — and then to press Back (or your chosen action) so the feed closes.

**What it actually does with it.** Detoxo looks for the specific on-screen elements that mean "you're in a short-video feed." That check runs entirely on your device, in the moment, and is thrown away immediately. It's the engine behind both blocking and the Reel Counter.

**What it does not do.** It does not read your messages, log your keystrokes, capture your screen, or send anything off your phone. There's no server on the other end — the detection logic is built into the app.

This is the heart of Detoxo, which is why it's the one permission you can't skip. When it's on, a small ongoing notification ("Detoxo is active") stays in your tray so you always know protection is running.

---

## Display over apps — required

**What you'll see:** "Display over apps" — *Shows the block / PIN screen over other apps.*

**Why it's needed.** When Detoxo blocks a feed or needs to ask for your PIN, it has to draw *on top* of whatever app you're in. This is the standard Android "overlay" permission (you may see it called "Display over other apps") that lets one app appear above another.

**What it also powers.** The optional floating **Reel Counter bubble** — the little draggable badge that shows how many Reels you've seen today — is drawn using this same permission. If you never grant it, the bubble simply doesn't appear; nothing crashes.

**What it does not do.** It doesn't let Detoxo see or touch other apps' content. It only lets Detoxo *draw its own* screens (the block message, PIN prompt, counter bubble) over the top.

---

## If a switch won't turn on

You flip **Accessibility** or **Display over other apps**, and Android refuses — showing something like *"Restricted setting"*, or a shield with *"App was denied access — access to this permission can put your personal and financial info at risk."* The switch stays off.

**This isn't a problem with Detoxo, and nothing is wrong with your phone.** Android 13 and later lock a small set of powerful switches for any app that wasn't installed from an app store, until you confirm you meant to turn them on. It's a blanket rule; it applies to every sideloaded app, whatever it does.

**The fix takes about ten seconds, once:**

1. Open Android's **Settings → Apps → Detoxo**.
2. Tap the **⋮** menu at the top right.
3. Choose **Allow restricted settings**.
4. Come back to Detoxo and tap **Grant** again.

A few notes that save time:

- The ⋮ entry usually appears only *after* you've tried the blocked switch once — so try the switch first, dismiss the message, then go to App info.
- On some phones it sits at the **bottom of the App info page** rather than in the ⋮ menu.
- The confirmation is **per app, not per permission** — doing it once unblocks Accessibility, Display over apps and uninstall protection together.

Detoxo watches for this. If it notices a grant isn't taking, the button on the permission changes to **Fix this** and walks you through the same steps with a shortcut straight to the right screen.

**Installing from the Play Store avoids this completely** — Play is a trusted installer, so the restriction never applies.

---

## Usage access — recommended

**What you'll see:** "Usage access" — *Powers app usage limits.*

**Why it's useful.** This is Android's app-usage information. Detoxo uses it to power **daily usage limits** — so it can tell how long you've spent in a given app and act when you hit your cap.

**What it does not do.** It reads usage stats on-device to enforce your own limits. It isn't used to profile you and it isn't sent anywhere. Skip it and blocking still works fully; you just won't have usage-limit features.

---

## Unrestricted battery — recommended

**What you'll see:** "Unrestricted battery" — *Keeps the blocker alive. Pick Detoxo, then "Don't optimize".*

**Why it's useful.** To save power, Android aggressively puts background apps to sleep. That's usually great — but a blocker that's asleep isn't blocking. Granting a **battery-optimization exemption** tells the system to leave Detoxo running so it's there the instant you open a feed.

**How to grant it.** Tap **Grant** and Android shows a one-tap confirmation asking whether to let Detoxo run in the background — choose **Allow**. (On some phones this opens the Battery optimization screen instead; there, find **Detoxo** and choose **Don't optimize**.)

**What it does not do.** It doesn't drain your battery on purpose or run extra work — Detoxo's blocking is lightweight. It just asks Android not to force-stop the protection you turned on. Highly recommended, especially on phones that are strict about background apps.

---

## Uninstall protection (Device admin) — recommended, optional

**What you'll see:** "Uninstall protection" — *Optional uninstall protection.*

**Why it's useful.** This registers Detoxo as a "device admin," which does two things:

1. **Makes Detoxo harder to uninstall** in a weak moment — you can't just delete it on impulse mid-scroll.
2. **Enables the optional "lock screen" block action**, where instead of pressing Back, Detoxo can lock your phone when you hit a blocked feed.

**Fully your choice, and reversible.** It's off by default and you never have to enable it. If you do, you can turn it back off anytime from Settings (or Android's Security settings), and then Detoxo uninstalls normally. Detoxo only asks Android for the minimum device-admin abilities it needs (lock the screen, notice a sign-in) — nothing more.

---

## Notifications — recommended

**What you'll see:** "Notifications" — *Alerts you if protection stops.*

**Why it's useful.** Detoxo keeps a quiet, always-on notification so you can see at a glance that it's active — and so it can alert you if protection ever stops. Some phones silently kill the protection service (for example after a force-stop), and Android doesn't let an app restart it by itself — so Detoxo checks in the background every few minutes and, if protection has died, posts a **"Protection stopped"** alert that takes you straight to the settings screen where one tap turns it back on. Without notification permission, that safety net can't reach you. On newer Android versions, apps need your permission to post notifications, which is why it's on the list.

This is the one permission granted with a simple in-app "Allow?" pop-up rather than a trip to system settings. If you once dismissed that pop-up with "Don't ask again", Android stops showing it — so the button then reads **Open settings** and takes you straight to Detoxo's system settings to switch notifications back on.

---

## Your privacy, plainly

- **On-device by design.** Detection and the Reel Counter run locally on your phone. The "what's on screen" check happens in the moment and isn't stored or transmitted.
- **Offline-first blocking.** Detoxo's blocking configuration is built in and doesn't rely on a custom server. It doesn't upload your scrolling, your messages, your app list, or the specific sites and videos you see. Your block history stays on your device.
- **Anonymous diagnostics.** To fix crashes and improve Detoxo, the app sends **anonymous, aggregated** usage and diagnostic data to Google Firebase: which screens you open, when you change plan or toggle protection, how often blocking fires (by app *category*, e.g. "YouTube" — never the exact video or URL), rough reel-count totals, crash reports, and performance timings. It's tied to a **random ID** created on your device — not your name, email, or an account (there's no login). A setting to turn this off is planned.
- **No ads, no ad tracking, no selling your data.**
- **You're in control.** Only two permissions are required; the rest are optional and reversible. You can review and change every one of them anytime under **Settings → Permissions**, without redoing onboarding.

If a permission ever gets switched off (say, after a system update), Detoxo notices when you reopen it and simply invites you to turn it back on — no lock-in, no dark patterns.

---

## Related

- [All user guides](00-index.md)
- Engineering detail (for the curious): [../code_docs/13-onboarding-permissions.md](../code_docs/13-onboarding-permissions.md), [../code_docs/04-native-android-layer.md](../code_docs/04-native-android-layer.md)
