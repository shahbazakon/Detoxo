# Frequently Asked Questions

Short, straight answers about how Detoxo works, what it does with your data, and how to control it. If something here doesn't match what you're seeing, email us at **errorxperts@gmail.com**.

---

## Why does Detoxo need the Accessibility permission?

Detoxo is a reel and short-form-video blocker. To do its job it has to notice the *moment* a Reels / Shorts / infinite-feed screen opens inside another app (Instagram, YouTube, Snapchat, and so on) and act right then. On Android, the only way one app can tell what screen another app is showing is Android's **Accessibility Service**.

Detoxo uses that permission for exactly one purpose: to recognise a short-video feed on screen and pull you out of it. That's also why it's Android-only — there is no equivalent permission on iPhone (see below).

## Does Detoxo read, collect, or upload my data?

Your **content** stays private — what you watch, browse, and type never leaves your phone. Detoxo does send a small amount of **anonymous, aggregated** usage and crash data (via Google Firebase) so we can fix bugs and improve the app.

- **Never leaves your phone:** the sites and apps you open, the reels you watch, your messages, your blocked-events history, your installed-app list, **your screen-time and per-app usage figures (the Insights screen)**, and your PIN. The Accessibility permission only *recognises* a reel feed in the moment to block it — it doesn't capture or upload what's on your screen, and your PIN lives in your device's secure storage.
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

This holds for notifications too: if you switch on Notification silence, a
protected app still notifies you normally, always.

## Android says "restricted setting" and won't let me turn on Accessibility

If you installed Detoxo from an APK rather than the Play Store, Android blocks a few powerful switches until you confirm you meant to enable them. You'll see *"Restricted setting"* or *"App was denied access"*.

Open **Settings → Apps → Detoxo**, tap the **⋮** menu at the top right, and choose **"Allow restricted settings"** (on some phones it's at the bottom of the App info page instead). Then come back to Detoxo and tap **Grant** again. It's a one-time confirmation and unlocks every affected switch at once.

The ⋮ entry usually shows up only after you've tried the blocked switch once. Detoxo also notices when a grant isn't taking and offers a **"Fix this"** button that jumps you to the right screen. Installing from the Play Store avoids this entirely — see [Permissions explained](03-permissions-explained.md#if-a-switch-wont-turn-on).

## How does Detoxo actually stop me from scrolling?

When Detoxo detects a short-video feed, it pulls you out of it and shows its **block screen** — a full-screen card that names what was blocked (say, "Instagram Reels is blocked by Detoxo"), why (your plan, your App blocker list, your website blocklist), and today's reel count. The standard action underneath is a simple **Back** press — the same as if you'd tapped your phone's back button — which closes the feed. (An optional short vibration can confirm it happened.)

The block screen always gives you a way out: **Go home**, **Open Detoxo**, or **Back to Instagram** (or whichever app), which drops you on the app's previous screen so you can carry on with messages, search and the rest. **Back to …** counts down for five seconds before it unlocks — long enough for the block to register before the reflex tap — while the other two work at once; you can drop the wait under **Appearance → Block screen → Friction**. If the exit already dropped you on your home screen or in the app you came from, that button just reads **Dismiss**. Swiping back from the screen's edges is deliberately ignored while it is up. Depending on your setup, the action can instead **close the app** or **lock the screen**, but a back-press is the default and the least disruptive. If the "Display over other apps" permission is missing, or you switched the block screen off, Detoxo falls back to a short toast.

## A full screen appeared when a reel was blocked — how do I get out, or turn it off?

That's the block screen. Tap **Go home** to leave, **Open Detoxo** to jump into the app, or **Back to …** to return to the app you were in (minus the feed) once its five-second wait is over. To turn it off, open **Settings → Appearance → Block screen** and flip the switch; blocks then go back to the short toast. The same card lets you pick its look — background, light/dark theme, whether it shows today's reel count and how many times you've opened the app today (that line needs the **Usage access** permission and simply stays away without it), and whether the wait is on — with a live preview and a **Try it on your phone** button.

## What's the difference between Block All, One Reel, Unblock, Conscious, and Pause?

These are the five ways Detoxo can behave. You pick whichever fits your goal from the mode cards on the home screen:

| Mode | What it does |
| --- | --- |
| **Block All** | The strict default, and a **base** mode. Every reel/short you open is closed straight away, and it stays on until you change it. |
| **One Reel** | *Temporary.* Lets a single reel play, then returns to your base mode. Scrolling to the next reel is what ends the peek. Tap **One Reel** again whenever you want another single clip — each tap re-arms one reel. |
| **Unblock** | *Temporary.* You decide how many reels to release: tap the **Unblock** card, turn its dial to a count (2–20), and confirm. You can watch that many, then it returns to your base mode — tap **Unblock** and confirm a new count to unlock more. |
| **Conscious** | An "earn-as-you-abstain" **base** mode. You build up a small allowance of watch-time by *staying off* reels (about 1 minute banked for every 10 minutes away, up to 10 minutes saved). While you have allowance, reels play; when it runs out, blocking kicks back in until you've earned more. It keeps you honest without a hard wall. |
| **Pause** | *Temporary.* A short, deliberate break. You choose a window (2–10 minutes); during it, reels and blocked websites are allowed. When the timer runs out, it returns to your base mode. (Apps you've fully locked on the Block apps screen stay locked through a Pause.) |

Two of these **stick** — **Block All** and **Conscious** are your *base* mode — and three are **temporary** overrides (**One Reel**, **Unblock**, **Pause**) that auto-return to whichever base mode you were on once they finish. (See "What happens after One Reel, Unblock, or Pause finishes?" below.)

Tip: with **Conscious**, pausing a video doesn't secretly bank you extra time — the allowance only builds while you're genuinely off short-video feeds. And if you dip into a temporary mode (One Reel, Unblock, or Pause) while Conscious is your base, the time you've already banked is **kept** — it's waiting for you when Conscious returns, not reset to zero. (Choosing Conscious fresh does start from zero, and the bank also resets at the start of each day — yesterday's abstinence doesn't buy this morning's scroll.)

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

- A video only counts **once you've stopped on it for about a second** — flicks, half-swipes and scrolling the comments are ignored, and the same reel never counts twice, so the number reflects the reels you actually saw.
- It counts reels and shorts, but deliberately **skips** regular feeds, Stories, and statuses (those aren't "reels").
- The count keeps running whether blocking is on, off, or paused. It's on by default because awareness alone tends to change habits.

You can see the number three ways: inside the app, on an optional **floating bubble** that hovers over your screen while you watch, and on an optional **home-screen widget**. The bubble and widget both keep working even if you close the Detoxo app.

## How does Detoxo measure my daily "screen time"?

The ring on your home screen shows how much time you've spent today in the social apps Detoxo watches, filling toward your daily limit. That time is measured **entirely on your device**, using the **same Accessibility permission** the blocker already uses — there's **no extra permission** and nothing is sent anywhere. Detoxo simply notices while one of those apps is active in the foreground and adds up the time.

Because it works from those on-screen signals, it counts your *active* time well but can **undercount long, silent playback** — for example a video left playing untouched, which produces very little on-screen activity. So treat the number as a close, honest estimate rather than a stopwatch. It resets at the start of each new day, together with your reel count.

If you want the exact figure instead, **Activity → Insights** shows your whole-phone screen time taken straight from Android's own records — the same numbers as Settings → Digital Wellbeing. The two answer different questions: the ring is time in the social apps Detoxo watches (and drives your limit), Insights is your whole day, every app.

## What's in Activity → Insights, and why is it sometimes empty?

Insights shows your real screen time for today: the total, how much of it was on distracting apps, how many times you picked up your phone, how often you switched apps, and which apps took the most time. It reads Android's own screen-time records, so it should match Digital Wellbeing.

It needs the optional **Usage access** permission. If you haven't granted it, Insights shows a **Grant** button and **no numbers at all** — on purpose. A screen of zeros would look identical to a genuinely quiet day, and we'd rather show you nothing than something wrong.

Two things worth knowing: Android counts an app as "in use" whenever it's on screen even if you weren't touching it (so does everyone else), and **history starts the day you first open the screen** — Android only keeps about a week of detail, so we can fill in yesterday but not last month. From then on Detoxo keeps 90 days.

## Is my app-by-app usage sent anywhere?

No. Your screen-time totals, your per-app breakdown, your pickups — all of it is calculated and stored **on your device only**, in Detoxo's local storage, and none of it goes into the anonymous diagnostics described above.

Two things we'd rather say than leave you to assume. Apps you've marked as **protected** (your bank, UPI or password manager) are left out of the app list entirely and are never written down — their time still counts toward your total, but they're never named. And Detoxo's local data is currently part of Android's normal app backup, so with Google backup switched on it can be copied to your Google account the way any app's data is; excluding it is on our list.

Insights is also completely free; there's no paywall on knowing how you spend your own time.

## How do I set or change my daily limit?

You first set a daily limit during setup by dragging a dial (the "Here's the deal" step). To change it any time, open **Settings → Daily limit** (or tap the pinned row at the top of **Rules**), drag the slider, and tap **Save limit** (0 means "no limit"). Your home-screen ring updates **immediately** and fills toward whatever you set. When today's reel time reaches the limit, Detoxo **blocks every reel feed until midnight** — the block screen says "Your daily limit is used up" — while the rest of each app keeps working. A Pause lifts it like any other block. The limit is measured by the reel counter, so it can only be enforced while the counter is on.

## Detoxo created a rule for me — where did it come from?

That's your **starter rule**, set up from what you said mattered most during first-run setup: *sleeping properly* gets you a nightly 22:00–07:00 block, *focus* gets weekdays 09:00–17:00, and the rest get a 30-minute daily budget. It covers the feeds you picked, and it is written the moment you grant the required permissions — not before, because a rule that cannot be enforced yet is a rule that does nothing.

It's an ordinary rule with nothing special about it: open **Rules** to change the hours, swap the apps, switch it off, or delete it. If you were already using Detoxo before this feature existed, no rule was created for you.

---

## Do I have to finish setup in one go?

No. Every answer is saved the moment you give it, and the step you're on is remembered — close the app, restart your phone, or leave it a week, and you'll come back exactly where you left off rather than starting from the beginning.

---

## What are rules, and how do I create one?

Rules are blocks with a clock. Tap the **Rules** card on your dashboard. With no rules yet, the quickest start is **Start from a preset** — *Work hours*, *Sleep*, *Dinner* or *Doomscroll budget* opens a rule already filled in for you to adjust and save. Otherwise tap **New rule** and pick a **Schedule** (block during set hours on chosen days — an end time before the start time means overnight), a **Daily time limit** (a budget of minutes, then blocked until midnight) or an **Open limit** (a number of launches a day, then blocked until midnight). Then choose what it covers: categories like Short-form video or Social, specific apps, and — for schedules — reel feeds and websites. Each rule has an on/off switch and shows where you stand ("Active now", "22/30 min", "Next Mon 09:00"). You can keep up to 50.

## My time limit ran out but the app opened anyway — why?

Time and open limits are counted from Android's own usage records, and Detoxo re-checks them in the background about every 15 minutes, so a budget now runs out and starts blocking **without you opening Detoxo**. Two things can still delay it: the check runs on that 15-minute rhythm, so a block can land a few minutes after the budget is technically gone, and limits need **Usage access** — the Rules screen offers a button to grant it if a limit can't count. Schedules never have this gap; they are planned a week ahead and fire on time on their own.

## Can I turn Usage access off to get around a limit?

No — not for a limit that has already run out. Switching Usage access off stops Detoxo from measuring anything new, but a block that is already up stays up for the rest of the day.

## Can I limit how often I let myself off the hook?

Yes. **Settings → Protection → Allowances** caps how many "allow this for a while" unblocks you can take in a day — 1, 2, 3 or 5. It ships as **Unlimited**, so nothing changes unless you turn it on, and the duration chips tell you how many you have left before you spend one.

Locked rules are rationed separately, and always: lifting one costs an override, two a week.

## Where can I see what's currently unblocked?

The home screen shows an **Allowed right now** card whenever something is — the app, feed or site, when it goes back to being blocked, and a **Resume** button to end it early. It isn't there when nothing is allowed. The **Activity → Events** tab also shows how many overrides you've spent this period and the reasons you gave.

## Does Pause switch my rules off too?

Yes for normal rules, for the length of the Pause — a Pause is your break button and lifts schedules and limits the same way it lifts reel blocking. Two exceptions: apps you locked in **Block apps** stay locked through a Pause, and so does any rule you mark **Strict**.

## What does "Strict" do on a rule?

It removes your own escape hatch. A strict rule keeps blocking apps, reel feeds **and websites** even while Detoxo is paused — it's for the rules you set precisely because you know future-you will want to skip them. The switch is in each rule's editor and is off by default, so nothing changes unless you turn it on.

## The block screen now tells me when I get the app back

Yes — when a schedule or a daily limit raises the wall, it says when it lifts: "Blocked by a schedule · Unlocks at 5:30 PM", or "Your daily limit is used up · Resets at midnight". The time follows your phone's 12- or 24-hour setting.

## What is the "day streak" on my dashboard?

The small **day streak** beside your reels count is how many days in a row you've stayed **under your daily limit**. It ticks up each day you finish under the limit and resets if you go over or skip a day — a gentle motivator to keep your scrolling in check. It's counted on your device while the app is open; nothing is uploaded.

## The floating bubble needs "Display over apps" — why?

The little counter bubble floats on top of whatever app you're in, so Android asks for the **Display over apps** permission (sometimes shown as "Draw over other apps") before it can appear. Counting works everywhere without it; you just won't see the bubble. The same permission draws the **block screen** — without it, blocking still works but you get a short toast instead of the full-screen card.

If the bubble or the block screen is switched on but the permission is missing, its card on the Appearance screen tells you so — tap the warning to open the setting; it clears on its own once granted.

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

## The dashboard (or a permission card) briefly says "Checking…" — is something wrong?

No. Right after launch, Detoxo may not have heard back from Android yet about a permission or the protection service, so instead of guessing it shows a neutral **"Checking…"** — on the dashboard's Protection Status card and on the setup screen's permission cards. It settles within a moment, and it never means something was revoked or turned off. (Detoxo deliberately doesn't flash "Protection off" or "denied" during that moment — a false alarm you learn to ignore would hide the real one.)

## Can Detoxo hide notifications from apps I've blocked?

Yes — switch on **Settings → Privacy → Notification silence**. While it's on, an app you've
locked in the App blocker, or one a rule is currently blocking, won't notify you at all: no
sound, no banner, nothing in the shade. When the block lifts — your schedule window ends, your
limit resets at midnight, you start a Pause — its notifications come back on their own. Nothing
is deleted; the app just stops interrupting you while it's off limits.

**Messages and calls still get through.** Detoxo silences the feed, not the person: a DM, a call,
an email, an alarm or a calendar reminder reaches you even from a locked app. Only the feed and
"come back and scroll" notifications are dismissed.

It needs one extra permission (*Notification access*) and is off until you turn it on. One thing to
know: an app that doesn't label its notifications at all has everything silenced while it's
blocked — most big apps label messages correctly, a few don't.

## Notification access sounds like a lot — what can Detoxo actually see?

Android has no "only these apps" version of this permission, so granting it does technically
expose every notification on your phone. Detoxo tells you that plainly before sending you to
the system screen, because you deserve to know before you tap.

What it does with it: it reads **which app sent the notification** and **whether that app labelled
it a message, call or alarm** — and nothing else. Not the title, not the message text, not who sent
it, not the images. If it came from an app you've locked or scheduled and isn't a message or call,
it's dismissed. Nothing is stored, written to a log, or sent anywhere,
and a dismissed notification is never read, changed or re-posted. Your protected apps are never
silenced. And when you turn the switch off, Detoxo **stops receiving notifications entirely**
rather than receiving and ignoring them.

## I got a "Protection stopped" notification — what does it mean?

Some phones silently kill Detoxo's protection service — most often after a force-stop or an aggressive battery "optimization" — and Android doesn't allow an app to restart it on its own. Detoxo checks in the background every few minutes; if protection has died while your master switch is still on, it posts a **"Protection stopped"** alert. Tap it and you land on the exact Accessibility settings screen where one toggle turns protection back on. (You'll see the alert at most once every few hours — it's a nudge, not a nag.) This is one reason the Notifications permission is worth granting.

## I tapped "Don't ask again" on notifications — how do I turn them back on?

Once you permanently dismiss the notification pop-up, Android won't show it again. Open **Settings → Permissions** (or the setup funnel) and the Notifications card's button now reads **Open settings** — tap it to jump straight to Detoxo's system settings and switch notifications on.

## Does Detoxo work on iPhone / iOS?

No — Detoxo is **Android-only**, and this isn't a temporary gap. The whole product depends on Android's Accessibility Service to see a reel feed and press Back. Apple's system deliberately doesn't let one app look inside another app or dismiss its screen, so there's simply no way to build the same reel-level blocking on iPhone. If you open Detoxo on an iPhone you'll see a short screen explaining this rather than broken controls.

## How do I take a break or turn Detoxo off?

- For a **quick break**, use **Pause** — pick 2–10 minutes and reels and blocked websites are allowed until the timer ends, then it returns to your base mode (Block All or Conscious) on its own. Apps you've fully locked on the Block apps screen stay locked through the break. This is the recommended way to step away without forgetting to turn protection back on.
- To **turn blocking off entirely**, open **Settings** and switch off **Protection** (the master switch for all detection). If you've set a PIN, Detoxo will ask for it first — that's the intentional speed bump that stops an impulsive "just turn it off."

The reel counter is controlled separately (**Count short videos** on the Appearance screen), so you can keep counting even with blocking off.

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

One more thing: too many wrong guesses starts a cooldown that grows with each miss (up to 24 hours). It survives force-quitting the app, and it's tied to the phone's internal uptime clock — so changing the date or time in Settings doesn't skip the wait.

## How do I uninstall Detoxo?

Uninstall it like any app — **unless** you turned on the optional **Device Admin** protection.

Device Admin is an opt-in feature that stops Detoxo from being uninstalled on impulse (and enables the lock-screen action). If you enabled it, Android won't let you remove the app until you first **remove Detoxo as a device administrator** — you can do that from Detoxo's own settings, or from your phone's *Settings → Security → Device admin apps*. After that, uninstall works normally. Turning off the Accessibility permission (in *Settings → Accessibility*) also stops all blocking immediately.

## Which apps and sites does Detoxo cover?

Detoxo targets the short-video feeds inside popular apps (think Reels, Shorts, and similar infinite-scroll video), plus it can bounce you off blocked websites — including an optional built-in adult-site list — when you browse. It focuses on the *feed*, so the rest of an app (messages, search, posting) keeps working normally. And for apps you want gone entirely, you can add **any app on your phone** to the Block apps list — see the next question.

## Can Detoxo block a whole app, not just its feed?

Yes. On the **Block apps** screen, tap **Add app** and pick any app from your phone. From then on, opening that app bounces you straight back to your home screen with a short "*App* is blocked by Detoxo" message — even if you were already inside it when the block landed. Each bounce counts toward your "Blocked today" number, and you can pause a block anytime by flipping the row's switch off (or delete it). Detoxo never blocks your home screen, itself, or your protected private apps (banking, payments, and the like).

## Can I let a blocked website through for a few minutes?

Yes — without unblocking it. On the **Website blocker** screen, tap the site's row (or swipe it left), choose **Allow** and pick 5, 15, 30 or 60 minutes. The row shows "Allowed until …" and the site opens normally until then; when the time is up, blocking switches itself back on — even if Detoxo never reopens. Tap **Resume** to end it early.

## Can I do that for an app, or for one feed?

Yes — that's the same thing now. On the **Block apps** screen each blocked row has a timer button, and when Detoxo blocks something the block screen itself offers **Allow for a while** — tapping it shows the durations right on that screen, so you never have to leave the app you're in. Pick 5, 15, 30 or 60 minutes and *only that thing* opens: every other app, feed and site stays exactly as protected as it was. It ends by itself, it survives a restart, and moving your phone's clock backwards won't buy you extra time. See [02-feature-walkthroughs.md](02-feature-walkthroughs.md) §18.

Two exceptions: adult sites are never unblockable this way, and a rule you marked **Locked** or **Strict** isn't either — that one needs an override.

## What does "locking" a rule actually do?

A locked rule has **no off switch**. You can't disable it, you can't delete it, you can't shrink what it covers, you can't change its hours, you can't loosen its daily limit, and a Pause doesn't lift it. You can rename it, and you can always make it cover *more*. Detoxo asks you to confirm before locking, because there is no unlock afterwards.

The way through is an **override**: two a week. Spending one means picking a reason and how long (up to an hour), and it steps that **one rule** aside for exactly that long — not your other rules, not your app blocks. It comes back on time whether or not Detoxo is running.

## I locked a rule and now I really do want it gone. What are my options?

There is deliberately no unlock inside the app — that's what makes locking mean something. Your options are an **override** (a temporary lift, twice a week), **Settings → Reset app data** (which clears everything Detoxo has stored, locked rules included), or turning Detoxo's accessibility permission off in Android Settings.

If you also have uninstall protection on, turn that off first in Settings → Protection.

## Can Detoxo just remind me instead of blocking?

Yes — turn on **Soft nudge** in Settings → Protection. Distracting apps then open normally,
and after five minutes in one a small card appears at the bottom telling you how long you've
been there. Nothing is blocked, nothing closes, and you can keep scrolling right past it; it
goes away by itself after a few seconds. It returns every five minutes after that, up to four
times a day per app, and the clock resets if you leave the app for a minute.

One thing people expect and don't get: the five minutes is **per visit**, not per day — two
short visits won't nudge you. If you want "tell me after 30 minutes today", use a **daily
limit** under Rules instead. See [02-feature-walkthroughs.md](02-feature-walkthroughs.md) §17.

## Where are the "block adult content" and "block websites of blocked apps" switches?

On the **Website blocker** screen, tap the tinted **Protection** pill at the start of the Popular sites row — it opens a small screen with both switches, and shows how many are on.

**Block adult content (18+)** covers every page of 200+ known adult sites plus every `.xxx`, `.porn`, `.sex` or `.adult` address, in any supported browser, on top of your own blocklist. Those blocks are counted in your stats but never named — the block screen (or the toast, if the screen is off) just says "Adult site blocked by Detoxo", and no adult site can show up in the "Most blocked" line. If you need one of those sites, switch the 18+ protection off for a while; per-site pause applies to your own blocklist entries.

## Detoxo says a browser is "not covered" — what does that mean?

Detoxo blocks websites by reading the address bar, and it only knows how to do
that in browsers it recognises — about thirty of them, including Chrome,
Firefox, Samsung Internet, Edge, Brave, Opera, DuckDuckGo and Vivaldi. In any
other browser it can't see where you are, so **your blocklist and the 18+ filter
do nothing there**.

Rather than let that pass quietly, the **Website blocker** screen lists the
browsers on your phone it can't cover, by name. If you see that message you have
three options: use one of the supported browsers instead, uninstall the one
that isn't covered, or add that browser to **Block apps** so it can't be opened
at all.

## Why does Detoxo ask for my PIN when I protect a browser?

**Protected apps** makes Detoxo go completely blind in an app — no reading, no
counting, no blocking. That's exactly what you want for a banking or UPI app.
But a browser is where the website blocker does its work, so protecting one
would switch off your blocklist and the 18+ filter inside it.

That's the same kind of change as turning blocking off, so it costs the same
thing: your settings PIN. Protecting a bank, a wallet or a password manager
still takes one tap with no PIN.

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
