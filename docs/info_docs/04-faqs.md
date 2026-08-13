# Frequently Asked Questions

Short, straight answers about how Detoxo works, what it does with your data, and how to control it. If something here doesn't match what you're seeing, email us at **errorxperts@gmail.com**.

---

## Why does Detoxo need the Accessibility permission?

Detoxo is a reel and short-form-video blocker. To do its job it has to notice the *moment* a Reels / Shorts / infinite-feed screen opens inside another app (Instagram, YouTube, Snapchat, and so on) and act right then. On Android, the only way one app can tell what screen another app is showing is Android's **Accessibility Service**.

Detoxo uses that permission for exactly one purpose: to recognise a short-video feed on screen and pull you out of it. That's also why it's Android-only — there is no equivalent permission on iPhone (see below).

## Does Detoxo read, collect, or upload my data?

Your **content** stays private — what you watch, browse, and type never leaves your phone. Detoxo does send a small amount of **anonymous, aggregated** usage and crash data (via Google Firebase) so we can fix bugs and improve the app.

- **Never leaves your phone:** the sites and apps you open, the reels you watch, your messages, your blocked-events history, your installed-app list, and your PIN. The Accessibility permission only *recognises* a reel feed in the moment to block it — it doesn't capture or upload what's on your screen, and your PIN lives in your device's secure storage.
- **Anonymous diagnostics we do collect:** which screens you open, when you change plan or toggle protection, how often blocking fires (by app *category* — e.g. "YouTube" — never the specific video or URL), rough reel-count totals, crash reports, and performance timings. This is linked to a **random ID** generated on your device — not to your name, email, or an account (there is no account or login).
- **Blocked websites stay private:** when Detoxo bounces you off a site, it records only *that a block happened* — never which site.
- **No ads, no ad tracking, and we don't sell your data.**

In short: Detoxo keeps what you *see and do* private, and shares only anonymous "how the app is used / did it crash" signals to make it better. (A switch to turn diagnostics off is planned.)

## Can Detoxo see my banking or payment apps?

No. Well-known sensitive apps — banking, UPI, DigiLocker, password managers,
authenticators and the like — are protected **automatically and permanently**;
there's nothing to configure and no way to accidentally switch it off. While a
protected app is on screen, Detoxo pauses itself completely: it doesn't read
the screen, doesn't count anything, never shows its bubble or blocks anything,
and its diagnostics don't record that you opened the app. When you switch back
to social media, protection resumes by itself. See what's covered — and add
apps of your own — under **Settings → Privacy → Protected apps**.

## Android says "restricted setting" and won't let me turn on Accessibility

If you installed Detoxo from an APK rather than the Play Store, Android blocks a few powerful switches until you confirm you meant to enable them. You'll see *"Restricted setting"* or *"App was denied access"*.

Open **Settings → Apps → Detoxo**, tap the **⋮** menu at the top right, and choose **"Allow restricted settings"** (on some phones it's at the bottom of the App info page instead). Then come back to Detoxo and tap **Grant** again. It's a one-time confirmation and unlocks every affected switch at once.

The ⋮ entry usually shows up only after you've tried the blocked switch once. Detoxo also notices when a grant isn't taking and offers a **"Fix this"** button that jumps you to the right screen. Installing from the Play Store avoids this entirely — see [Permissions explained](03-permissions-explained.md#if-a-switch-wont-turn-on).

## How does Detoxo actually stop me from scrolling?

When Detoxo detects a short-video feed, it gently pulls you out of it. The standard action is a simple **Back** press — the same as if you'd tapped your phone's back button — which closes the feed and drops you back to the previous screen. (An optional short vibration can confirm it happened.)

Depending on your setup, the action can instead **close the app** or **lock the screen**, but a back-press is the default and the least disruptive.

## What's the difference between Block All, One Reel, Unblock, Conscious, and Pause?

These are the five ways Detoxo can behave. You pick whichever fits your goal from the mode cards on the home screen:

| Mode | What it does |
| --- | --- |
| **Block All** | The strict default, and a **base** mode. Every reel/short you open is closed straight away, and it stays on until you change it. |
| **One Reel** | *Temporary.* Lets a single reel play, then returns to your base mode. Scrolling to the next reel is what ends the peek. Tap **One Reel** again whenever you want another single clip — each tap re-arms one reel. |
| **Unblock** | *Temporary.* You decide how many reels to release: tap the **Unblock** card, turn its dial to a count (2–20), and confirm. You can watch that many, then it returns to your base mode — tap **Unblock** and confirm a new count to unlock more. |
| **Conscious** | An "earn-as-you-abstain" **base** mode. You build up a small allowance of watch-time by *staying off* reels (about 1 minute banked for every 10 minutes away, up to 10 minutes saved). While you have allowance, reels play; when it runs out, blocking kicks back in until you've earned more. It keeps you honest without a hard wall. |
| **Pause** | *Temporary.* A short, deliberate break. You choose a window (2–10 minutes); during it, everything is allowed. When the timer runs out, it returns to your base mode. |

Two of these **stick** — **Block All** and **Conscious** are your *base* mode — and three are **temporary** overrides (**One Reel**, **Unblock**, **Pause**) that auto-return to whichever base mode you were on once they finish. (See "What happens after One Reel, Unblock, or Pause finishes?" below.)

Tip: with **Conscious**, pausing a video doesn't secretly bank you extra time — the allowance only builds while you're genuinely off short-video feeds. And if you dip into a temporary mode (One Reel, Unblock, or Pause) while Conscious is your base, the time you've already banked is **kept** — it's waiting for you when Conscious returns, not reset to zero. (Choosing Conscious fresh does start from zero.)

## How does Unblock mode work?

**Unblock** lets you release a set number of reels and then automatically returns to your base mode — think of it as **One Reel** with a dial.

1. Tap the **Unblock** card on the home screen; a **dialog opens with a dial**.
2. Turn the dial to choose how many reels to unlock — anywhere from **2 to 20**.
3. Tap **Unlock N reels** to start the session.

You can now watch that many reels. A reel only counts toward your allowance **after you've actually watched it for about 2 seconds** — so quickly scrolling past reels doesn't burn them, and a single reel that loops uses up just one. The card shows a live "**N of M reels left**" line. When the count runs out, Detoxo **returns to your base mode** (Block All or Conscious) — it won't quietly hand you more. To watch another batch, tap **Unblock** and confirm a count again; every confirmation gives you a **fresh allowance**. Like all blocking, Unblock needs Detoxo's Accessibility permission on.

## What happens after One Reel, Unblock, or Pause finishes?

Those three are **temporary** modes — one-off overrides. The moment their unit is done (the single reel is watched, the unlocked batch is used up, or the Pause timer ends), Detoxo **automatically switches back to your base mode** — whichever of **Block All** or **Conscious** you were on before. You don't have to re-arm anything: a detour never leaves you unprotected, and it won't bump you onto Block All if Conscious was your baseline. **Block All** and **Conscious** are the two "sticky" base modes — they stay put until *you* change them. (If Conscious was your base, your earned reel-time is kept across the detour, not reset.)

## How does the reel counter work — and is it separate from blocking?

Yes, the reel counter is **completely separate from blocking**. It runs on its own and simply tallies the short videos you actually watch, so you can see the number even if you never turn blocking on.

- A video only counts **after you've watched it for about 2 seconds** — quick flick-throughs are ignored, so the count reflects real watching, not accidental scrolls.
- It counts reels and shorts, but deliberately **skips** regular feeds, Stories, and statuses (those aren't "reels").
- The count keeps running whether blocking is on, off, or paused. It's on by default because awareness alone tends to change habits.

You can see the number three ways: inside the app, on an optional **floating bubble** that hovers over your screen while you watch, and on an optional **home-screen widget**. The bubble and widget both keep working even if you close the Detoxo app.

## How does Detoxo measure my daily "screen time"?

The ring on your home screen shows how much time you've spent today in the social apps Detoxo watches, filling toward your daily limit. That time is measured **entirely on your device**, using the **same Accessibility permission** the blocker already uses — there's **no extra permission** and nothing is sent anywhere. Detoxo simply notices while one of those apps is active in the foreground and adds up the time.

Because it works from those on-screen signals, it counts your *active* time well but can **undercount long, silent playback** — for example a video left playing untouched, which produces very little on-screen activity. So treat the number as a close, honest estimate rather than a stopwatch. It resets at the start of each new day, together with your reel count.

## How do I set or change my daily limit?

You first set a daily limit during the welcome tour by dragging a dial (the "See the number, set the line" step). To change it any time, open **Settings → Daily limit**, drag the slider, and tap **Save limit** (0 means "no limit"). Your home-screen ring updates **immediately** and fills toward whatever you set. Today the limit is a self-awareness target — it colors the ring green → amber → red and tells you when you go over, but it doesn't hard-stop you; for a firm stop use **Block All** or **Conscious**.

## What is the "day streak" on my dashboard?

The small **day streak** beside your reels count is how many days in a row you've stayed **under your daily limit**. It ticks up each day you finish under the limit and resets if you go over or skip a day — a gentle motivator to keep your scrolling in check. It's counted on your device while the app is open; nothing is uploaded.

## The floating bubble needs "Display over apps" — why?

The little counter bubble floats on top of whatever app you're in, so Android asks for the **Display over apps** permission (sometimes shown as "Draw over other apps") before it can appear. It's optional — if you skip it, counting still works everywhere; you just won't see the bubble. Blocking does not need this permission.

## What happens when I tap the counter bubble?

It depends on the **Show time on tap** option (on by default, in the bubble's appearance settings):

- **On** — a **single tap** briefly flips the bubble to show today's watch time as a running clock (e.g. `1:23:45`), then back to the count; a **double tap** opens Detoxo.
- **Off** — a **single tap** opens Detoxo.

Either way, you can **drag** the bubble to any edge and it stays where you put it.

## Can I see how many reels I have left?

Yes — during a **One Reel** or **Unblock** session, the floating bubble doubles as an unlock countdown. It shows a teal "**N left**" badge with how many reels you still have to watch, ticking down as you scroll. When the session finishes (or you switch back to **Block All** or **Conscious**), the bubble **goes back to showing today's total reel count** on its own. This needs the counter bubble to be enabled, and it only appears while you're actually on a reel. You'll also see a matching remaining-count badge on the active **One Reel** / **Unblock** pill on the home screen.

## Will Detoxo drain my battery?

No, the impact is small. Detoxo is built to be light: it only reacts briefly when a screen changes, limits how often it checks each app, and caps how much work it does per check. There's no constant polling and nothing running in the cloud.

You will see a permanent, silent notification ("Detoxo is active") in your tray. That notification is required by Android to keep the blocker alive in the background — it's a status marker, not an alert, and it makes no sound.

## I tapped "Don't ask again" on notifications — how do I turn them back on?

Once you permanently dismiss the notification pop-up, Android won't show it again. Open **Settings → Permissions** (or the setup funnel) and the Notifications card's button now reads **Open settings** — tap it to jump straight to Detoxo's system settings and switch notifications on.

## Does Detoxo work on iPhone / iOS?

No — Detoxo is **Android-only**, and this isn't a temporary gap. The whole product depends on Android's Accessibility Service to see a reel feed and press Back. Apple's system deliberately doesn't let one app look inside another app or dismiss its screen, so there's simply no way to build the same reel-level blocking on iPhone. If you open Detoxo on an iPhone you'll see a short screen explaining this rather than broken controls.

## How do I take a break or turn Detoxo off?

- For a **quick break**, use **Pause** — pick 2–10 minutes and everything is allowed until the timer ends, then it returns to your base mode (Block All or Conscious) on its own. This is the recommended way to step away without forgetting to turn protection back on.
- To **turn blocking off entirely**, open **Settings** and switch off **Protection** (the master switch for all detection). If you've set a PIN, Detoxo will ask for it first — that's the intentional speed bump that stops an impulsive "just turn it off."

The reel counter is controlled separately (in the reel counter screen), so you can keep counting even with blocking off.

## I set a PIN — why does Detoxo ask for it again when I switch back?

That's **Smart Auto Lock**. When the PIN guards opening the app, Detoxo re-locks
after you leave it — immediately, after a delay you pick (15 s to 5 minutes;
1 minute is the default), or only when the screen turns off. Tune it in
**Settings → PIN lock → Re-lock after leaving Detoxo**, or set it to **Never**
to only lock on relaunch. Detoxo always asks again after a phone restart.

While you're there, **Hide screen in Recents** blanks Detoxo's card in the app
switcher so your settings and counts aren't visible at a glance (it also blocks
screenshots of the app). And the lock screen accepts three ways in: your Detoxo
PIN, your fingerprint or face, or your device PIN/pattern/password.

## I set a PIN and forgot it — how do I get back in?

**There's no reset, and that's on purpose.** Your PIN is stored (hashed) on your phone and nowhere else — there's no account, no server, and no support code. Any code Detoxo could accept would be a bypass that anyone holding your phone could use too, which would make the lock decorative.

If you're locked out for good, the way back is to **uninstall Detoxo and install it again**. That clears the PIN along with your settings, blocklists and counts, and you start fresh. If you turned on uninstall protection, switch it off first in *Settings → Security → Device admin apps*.

Detoxo says this plainly on the PIN setup screen and behind **"Forgot PIN?"** on the lock screen, so it shouldn't be a surprise — pick something you'll remember.

## How do I uninstall Detoxo?

Uninstall it like any app — **unless** you turned on the optional **Device Admin** protection.

Device Admin is an opt-in feature that stops Detoxo from being uninstalled on impulse (and enables the lock-screen action). If you enabled it, Android won't let you remove the app until you first **remove Detoxo as a device administrator** — you can do that from Detoxo's own settings, or from your phone's *Settings → Security → Device admin apps*. After that, uninstall works normally. Turning off the Accessibility permission (in *Settings → Accessibility*) also stops all blocking immediately.

## Which apps and sites does Detoxo cover?

Detoxo targets the short-video feeds inside popular apps (think Reels, Shorts, and similar infinite-scroll video), plus it can bounce you off blocked websites — including an optional built-in adult-site list — when you browse. It focuses on the *feed*, so the rest of an app (messages, search, posting) keeps working normally.

## How do I get help, report a bug, or suggest a feature?

Open the menu (top-right) and tap **Help & support**. You'll find: **Report an issue** (explains and turns on the feedback button, or lets you file a bug with a screenshot right away), a searchable **FAQ**, **Feature tutorials** (replay the dashboard walkthrough or a quick tour of the feedback button), and **Share an idea** (a simple box that opens your email pre-filled to us) — all routing to **errorxperts@gmail.com**. Under **Legal**, you can also open the **Privacy Policy** and **Terms & Conditions** right inside the app.

## How do I update Detoxo?

Detoxo checks the Play Store for a newer version when you open the app; if one is available it shows an **Update available** card with **Update now** (opens the Play Store) or **Later**, and you can **Skip this version** to stop being reminded about that one. To check on demand, open **Settings** and tap the **app-version card** at the bottom — if an update is ready it shows a compact **Update** button there, and if you're already current it just says so. Once in a while an update is **required** (an important fix); that card can't be dismissed until you update. Update checks run on Android only; on iPhone the app is a preview and doesn't check.

---

**Related (for the technically curious):**
[../code_docs/03-detection-engine.md](../code_docs/03-detection-engine.md) ·
[../code_docs/05-plans-pause-conscious.md](../code_docs/05-plans-pause-conscious.md) ·
[../code_docs/17-content-counter.md](../code_docs/17-content-counter.md) ·
[../code_docs/15-ios-cross-platform.md](../code_docs/15-ios-cross-platform.md)
