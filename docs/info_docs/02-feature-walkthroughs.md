# Feature Walkthroughs

Step-by-step how-to for everything Detoxo does — in plain language, using the same
button and screen names you see in the app. Detoxo is Android-only, and
everything here runs **on your device** (this build doesn't send your activity to
a server).

If you just want the big picture first, read [Product Overview](01-product-overview.md).
For the "why does it need that?" behind each permission, see
[Permissions Explained](03-permissions-explained.md).

---

## 1. First run: the setup conversation

The first time you open Detoxo you'll walk through five short steps. It's a
conversation, not a slideshow — most steps ask you something, and the answers
decide what Detoxo sets up for you.

1. **Take your time back** — what Detoxo does: it spots Reels, Shorts and
   infinite feeds the instant they play and pulls you out, right inside the apps
   you already use. It blocks the reels, not the app.
2. **A few quick things** — your first name (optional), roughly how long you
   spend on short-form video a day, and what matters most to you right now
   (focus, sleep, being present, how scrolling makes you feel, or something
   else).
3. **The maths** — at the rate you just gave, how many days of your next five
   years that adds up to. It's arithmetic on your own answer, not a judgement.
4. **What should Detoxo guard?** — pick the feeds to protect from the apps you
   actually have installed. Instagram's Feed, Reels and Stories collapse under
   one tile, so you can be as broad or as picky as you like. You need to pick at
   least one.
5. **Here's the deal** — the promise, in plain terms, plus a **drag dial** for
   your daily short-form time. Spin it to set the **daily limit** your
   home-screen ring fills toward (change it any time in **Settings → Daily
   limit**).

Tap **Next** to move on, **Back** (top-left) to change an answer, or **Skip**
(top-right) on the first three steps to jump straight to picking your feeds. If
you skip the questions, Detoxo sets up the 30-minutes-a-day budget it shows you
on the last step — you always get the rule you were promised.

**You can stop at any point.** Every answer is saved the moment you give it, and
the step you're on is remembered — close the app, restart your phone, whatever,
and you'll come back exactly where you left off rather than starting over.

When you finish, Detoxo takes you to permission setup (next section). **The
moment you grant the required permissions, Detoxo sets up your first rule for
you**, based on what you said matters most:

| You picked | Detoxo sets up |
|---|---|
| Sleeping properly | Feeds blocked every night, 22:00–07:00 |
| Focus and getting things done | Feeds blocked weekdays, 09:00–17:00 |
| Being present · How scrolling feels · Something else | 30 minutes of feed a day, then blocked until tomorrow |

It's an ordinary rule like any other — open **Rules** to change the hours, the
apps, or delete it entirely.

> Already using Detoxo before this update? Nothing changes for you — you won't be
> asked to go through setup again, and no rule is created behind your back.

> You can replay the in-app feature tour later from **Help & support → Feature
> tutorials → Dashboard tour**.

---

## 2. Granting permissions ("Set up protection")

For Detoxo to detect reels and pull you out of them, it needs a couple of Android
permissions. The **Set up protection** screen lists them in two groups —
**Required to block** and **Recommended** — with a short "why" under each, and a
progress bar showing how many required ones are granted.

**The two required permissions:**

| Permission (app label) | What it lets Detoxo do |
|---|---|
| **Accessibility** | Detect and block reels & shorts, and read the browser address bar for the website blocker. |
| **Display over apps** | Show the block / PIN screen on top of other apps, and float the reel-counter bubble. |

**How to grant one:**

1. Tap **Grant** next to a permission.
2. Detoxo opens the matching Android system screen (for example, the
   Accessibility list). Turn Detoxo on there and confirm.
3. Press back to return to Detoxo — the screen refreshes automatically and ticks
   off what you just granted.

The bottom button stays disabled and reads **Grant required permissions** until
both required ones are on; then it becomes **Continue** and takes you home.

> **A brief "Checking…" is normal.** Right after launch, a card can show a
> neutral **"Checking…"** for a moment while Detoxo reads the real status from
> Android. That's not a denial
> and not "protection off" — it settles on its own, usually within a second, and
> never un-grants anything you've already set up.

**Recommended (optional) permissions** — worth enabling, but not required:

| Permission | What it adds |
|---|---|
| **Notifications** | A heads-up if protection ever stops. |
| **Usage access** | Powers app-usage limits. |
| **Unrestricted battery** | Keeps the blocker alive in the background so your phone doesn't put it to sleep. Opens Android's battery-optimization list — switch it to **All apps**, pick **Detoxo**, choose **Don't optimize**. |
| **Uninstall protection** | Optional device-admin lock that makes Detoxo harder to remove on impulse. |

You can skip the optional ones now and turn them on later from
**Settings → Permissions**.

> Detoxo never trusts a "maybe" — after you return from a system settings screen
> it re-checks the real state, so the list always reflects what's actually on.

---

## 3. Choosing a blocking mode (how strict blocking is)

Your **Blocking Mode** decides what happens when Detoxo spots a reel. You pick it
from the big **Command Center** card on the home screen. Below the main dial the
modes appear as a **horizontal, swipeable row of pills** — **Block All**, **One
Reel**, **Unblock**, **Conscious**, and **Pause** (swipe sideways to reach all
five). The mode you're on is the highlighted pill, and while a **One Reel** or
**Unblock** session is live its pill shows a small remaining-count badge — plus a
live countdown/ring while a timed mode is running.

The five modes fall into two groups:

- **Base modes — they stick.** **Block All** (the default) and **Conscious**. Pick
  one and it stays put until you change it yourself.
- **Temporary modes — they auto-return.** **One Reel**, **Unblock**, and **Pause**
  are one-off overrides. When their unit finishes (the reel is watched, the batch is
  used up, the timer ends) Detoxo **automatically switches back to whichever base
  mode you were on** — Block All *or* Conscious. So a quick detour never quietly
  leaves you unprotected, and never forces you back to Block All if Conscious was
  your baseline.

> **The screen-time ring.** When no timed mode is running, the big ring shows
> **today's screen time** in the social apps Detoxo watches, filling toward your
> **daily limit** (the one you set during onboarding — §6). It shifts **green →
> amber → red** as you approach the limit, and reads "*X over your Y limit*" once
> you pass it. Below the ring, a single plain line (no boxed card) shows your
> **Reels** watched today and your **day streak** — the number of consecutive days
> you've stayed under your daily limit. (Start a **Pause** or **Conscious**
> session and the ring switches to that session's live countdown.)

| Mode | What it does |
|---|---|
| **Block All** | The strict default and a **base** mode. Every reel or short Detoxo detects gets you pulled out immediately; it stays until you change it. |
| **One Reel** | *Temporary.* Watch a single reel, then it returns to your base mode. Tap it again to watch one more. See below. |
| **Unblock** | *Temporary.* Choose how many reels to unlock (a **2–20 dial**); watch that many, then it returns to your base mode. See below. |
| **Conscious** | A **base** mode — you *earn* watch-time by staying off reels first. See below. |
| **Pause** | *Temporary.* A short, timed break from reel and website blocking; then it returns to your base mode. (Apps you've fully locked stay locked.) |

### Block All

Tap **Block All**. That's it — from now on, whenever a reel or short appears,
Detoxo exits it (or closes / locks the app, depending on your block-mode choice
in Settings — see §9). Pick the **Block screen** mode there and it also shows its
**block screen**: a full-screen card that
names what was blocked ("Instagram Reels is blocked by Detoxo"), which plan did
it, today's reel count and how many times you've opened that app today, with
three ways out — **Go home**, **Open Detoxo**, or **Back to Instagram** (the app
minus its feed). That last one waits five seconds before it unlocks ("Back to
Instagram · 5…") so the block registers before the reflex tap; the other two are
instant. Swiping back from the screen's edges is ignored while the card is up. The
card stays put wherever the exit dropped you — the app itself, your home screen, or
the app you came from (there it simply reads **Dismiss**) — and disappears on its
own when you move on to a different app, turn the screen off, start a Pause, or
switch protection off. In **Conscious** the card also tells you your time bank is
empty; in **One Reel** / **Unblock** it says you've watched your reel(s). You can
restyle the card, drop the wait or the extra lines — or switch it off for app and
website blocks — under **Appearance → Block screen** (§8, §9). Whatever mode you
pick, the card always appears once your **daily limit** is used up (§6), when a
**schedule** you set kicks in, or when your **Conscious** bank runs dry — those are
commitments you made in advance, so Detoxo always shows you the wall for them.

### One Reel — watch one, then blocked

**One Reel** lets a single reel play, then locks blocking straight back on. It's
the lightest touch: enough to satisfy a quick curiosity without opening the
floodgates.

Tap the **One Reel** card to arm a fresh allowance of one reel. You can watch that
clip; the moment you **scroll on to the next reel**, Detoxo counts it and pulls
you out — and **returns you to your base mode** (Block All or Conscious). To watch
another, tap **One Reel** again: each tap re-arms a new single-reel allowance. While
the session is live the card shows a "**N of M reels left**" line so you can see
what's remaining.

### Unblock — choose how many, then it returns to your base

**Unblock** is One Reel with a dial: instead of exactly one reel, you decide how
many to let through before your base mode snaps back.

1. Tap the **Unblock** card — a **dialog opens with a dial**.
2. Turn the dial to pick a count — **2 to 20 reels**.
3. Tap **Unlock N reels** to start.

You can now watch that many reels; each time you **scroll to the next reel** it
counts one toward your allowance, and the card shows a live "**N of M reels left**"
line. Once you've used them up, Detoxo **returns to your base mode** (Block All or
Conscious) until you tap **Unblock** and confirm a new count — every confirmation
hands you a fresh allowance.

> Like every blocking mode, **One Reel** and **Unblock** need Detoxo's
> **Accessibility** permission switched on (§2) to detect and count reels.

### Conscious — earn your watch-time

**Conscious** is for when you want to be able to watch a little, but only if
you've stayed disciplined first. It works like a time bank:

- **While you stay off reels**, your bank fills up — about **1 minute of allowance
  for every 10 minutes** you abstain, up to a maximum of **10 minutes** banked.
- **While you watch a reel**, the bank drains in real time.
- **When the bank hits zero**, Detoxo pulls you out and blocking resumes until you
  earn more.

To turn it on: tap **Conscious** on the Command Center, then confirm in the popup.
The card then shows a live ring and a status line — *Conscious — earning* while
your bank fills, *Conscious — spending* while you're watching, and
*Conscious — ready* when you have allowance saved up. Turning Conscious off (from
the same popup) drops you back to **Block All**. Each time you switch Conscious
on fresh, you start with an empty bank — you always have to earn the first minute.

> **Your bank survives a detour.** If Conscious is your base mode and you dip into a
> temporary mode (One Reel, Unblock, or Pause), the reel-time you've banked is
> **kept** — when the detour ends and Conscious returns, you pick up where you left
> off, not from zero. (Only *choosing Conscious fresh* starts an empty bank.)

> **…but not overnight.** The bank resets at the start of each day, so
> yesterday's discipline doesn't buy this morning's scroll — every day you earn
> your watch-time fresh.

### Pause — a timed break

**Pause** temporarily suspends reel and website blocking so you can scroll
freely for a set number of minutes — handy when you genuinely want a breather
without turning protection off for good.

1. Tap **Pause** on the Command Center.
2. Drag the slider to choose a length — **2 to 10 minutes** (in 2-minute steps;
   4 minutes by default).
3. Confirm. The card shows a **live countdown** and a *Paused* banner.
4. When the timer runs out, Detoxo **returns to your base mode automatically** —
   Block All or Conscious, whichever you were on before the break. You can also tap
   **Resume** to end the break early.

> **App locks hold through a Pause.** Apps you've fully locked on the **Block
> apps** screen stay locked during the break — a Pause is for reels and
> websites, not a back door into an app you deliberately locked. To open a
> locked app, flip its switch off on the Block apps screen.

The countdown is enforced by the device itself, so the break ends on time even if
you close Detoxo in the meantime.

---

## 4. Building your app blocklist ("Block apps")

Open **App Blocker** from the home screen tile. On the home screen the
two blocker tiles show what you've actually set up — "3 apps blocked" once you
have a list, or "Not set up" until then, with the status dot lit only when
something really is being blocked. The counts refresh as soon as you come back
from either blocker screen.

The **Block apps** screen has two parts:

### Apps & feeds (the built-in catalog)

A curated list of the apps and feed surfaces Detoxo already knows how to detect —
Instagram, YouTube, TikTok, Facebook, Snapchat, browsers, and more. Only apps you
actually have installed are shown.

- Flip a row **on** to have Detoxo watch that app's reels/shorts.
- Flip it **off** to leave that app alone.
- Browsers are grouped separately, and a search box appears once the list is long.

Changes here take effect **immediately** through the detection engine — no restart
needed.

> On a fresh install, Detoxo pre-enables the popular reel apps you already have
> installed, so protection works out of the box.

### Your own apps

Below the catalog you can add any app with the **Add app** button: it opens a
picker showing every app on your phone — icon, name and all — so you just
search, tap one or several, and confirm. Apps you've already added are marked
and can't be picked twice. Can't find one (some work-profile apps hide from the
list)? Use **"Can't find it? Add manually"** to enter its name and package id
(for example `com.example.app`) — Detoxo checks the id's shape and tells you if
it can't be right, and just installed the app? Tap the **refresh** button next
to the search box. Your added apps show their real icons and can be toggled or
deleted any time; this section only appears once you've added something.

> **Good to know:** apps you add here are **really blocked**. Open one and
> Detoxo bounces you straight back to your home screen with a short
> "*App* is blocked by Detoxo" message (and a little vibration, if you have
> block vibration on). It works even if you were already inside the app when
> you added it, and each bounce counts toward your "Blocked today" number.
> Flip the row's switch off (or delete it) whenever you want the app back.
> Detoxo will never block your home screen, itself, or a protected app (§13).

---

## 5. Setting up the website blocker

Reels have a habit of following you into the browser, so Detoxo can block
distracting **websites** too. Open the **Web Blocker** tile on the home screen
to reach the **Website blocker** screen.

This works by reading the address bar in your browser, so it needs the same
**Accessibility** permission as the reel blocker (which you granted in §2).

**At the top**, a small dashboard shows **Blocked today**, **Total blocked**,
**Focus saved (min)**, and your **most-blocked** site — once you've blocked
something.

**Protection** — the first pill in the Popular sites rows (tinted, with a
shield and arrow) opens its own screen with two switches that each block a
whole category at once; the pill shows how many are on:

- **Block websites of blocked apps** — automatically blocks the websites that match
  the apps you've already blocked (e.g. blocking the Instagram app also blocks
  instagram.com, and blocking WhatsApp also blocks web.whatsapp.com). Detoxo's
  built-in app catalog knows the web home of every app it lists.
- **Block adult content (18+)** — blocks every page of 200+ known adult sites
  plus every `.xxx`, `.porn`, `.sex` or `.adult` address, in any supported
  browser. These blocks count toward your stats but are never named: no adult
  site name ever appears in the toast or the "Most blocked" line.

**Which browsers are supported?** Detoxo blocks websites by reading the address
bar, and it knows how to do that in about thirty browsers — Chrome, Firefox,
Samsung Internet, Edge, Brave, Opera, DuckDuckGo, Vivaldi and the rest. If you
have one it doesn't recognise, the Website blocker screen says so by name at the
bottom ("Not covered: …"), because in that browser your blocklist and the 18+
filter do nothing. Detoxo would rather tell you than look like it's protecting
you. If that happens, you can switch browsers or add the browser itself to
**Block apps**.

**Adding sites:**

1. **Popular sites** — two rows of chips (YouTube, Instagram, X, Reddit,
   Netflix, TikTok, and more) that scroll sideways together; tap one to block or
   unblock it, or scroll to the end and tap **Add website** for your own.
2. **Your blocklist** — tap **Add website** and type a domain (e.g.
   `youtube.com`). Detoxo cleans up what you type (it accepts full URLs,
   `www.`, subdomains) and warns you if it isn't a valid site or is already on
   the list.
3. Each row has a switch to enable/disable it. Swipe the row left — or just tap
   it — to reveal its actions: **Pause**, **Edit** (for sites you added
   yourself) and **Delete**. A search box appears once the list grows.

**Need a blocked site for a few minutes?** Tap the row, choose **Pause** and
pick 5, 15, 30 or 60 minutes. The row shows "Paused until …", the site opens
normally until then, and blocking switches itself back on when the time is up —
even if you never reopen Detoxo. Tap **Resume** to end the pause early.

When you're on a blocked site, Detoxo simply presses back to take you off it.

---

## 6. App blocker & daily limit

You first set a daily limit during setup (the drag dial on the "Here's the deal"
step — §1). To change it later, open **Daily limit** from **Settings → Daily
limit** (or the menu) to adjust the cap on how much time you want per day.

1. Drag the slider to your target — **0 to 180 minutes**, in 5-minute steps.
   (0 means "no limit set.")
2. Tap **Save limit**.

Your **home-screen ring** (§3) fills toward this limit as you watch reels, so
the number you set here is what the dashboard measures you against. The **Today**
card shows how much of today's reel time you've used against your cap, with a
progress bar, and it resets automatically at the start of each new day.

**It's a real stop.** When today's reel time reaches the limit, Detoxo blocks
every reel feed it knows — Reels, Shorts and the rest — until midnight, with the
block screen saying *"Your daily limit is used up."* That card shows whatever
block mode you chose and even if you switched the block screen off under
Appearance. The rest of each app keeps working; only the feeds are closed. A **Pause** lifts it like any other block
(§3). The limit is measured by the **reel counter** (§8), so if you switch the
counter off, the Daily limit screen tells you it can't be enforced until you turn
it back on. You'll also see the limit pinned at the top of **Rules** (§14).

---

## 7. Setting a PIN, biometrics & recovery

A PIN keeps you from disabling Detoxo (or changing protected settings) on impulse
— the whole point when your future self is the one trying to sneak past.

### Turn it on

1. Go to **Settings → PIN lock** and flip it on. This opens **PIN setup**.
2. Choose a **PIN type**:
   - **Custom** — your own **4–10 digit** code (the only real secret; stored
     safely, never in plain text).
   - **Date** — today's date as `ddMMyyyy`. Convenient, but it changes daily and
     anyone who knows the trick can unlock it.
   - **Time** — the current `HHmm`. Changes every minute.
3. Choose **where the PIN applies**:
   - **App** — ask for the PIN every time Detoxo launches.
   - **Settings** — ask before disabling blocking, resetting data, or changing the
     PIN.
4. With the App scope on, tune **Smart Auto Lock**:
   - **Re-lock after leaving Detoxo** — pick when the lock re-arms after you
     switch away: immediately, after 15 or 30 seconds, 1 or 5 minutes (the
     default), when the screen turns off, or never (only on relaunch). Detoxo
     always locks again after a phone restart.
   - **Hide screen in Recents** — blanks Detoxo's card in the app switcher so
     nobody glimpses your settings or counts. This also blocks screenshots of
     the app while it's on.
5. Optionally turn on **Unlock with fingerprint or device credential**.
6. Save.

   The screen warns you plainly that there is no reset — pick something you'll
   remember.

### Fingerprint & device-credential unlock

If your phone supports it and you enabled it at setup, the lock screen offers a
fingerprint shortcut (and can prompt automatically). The system sheet shows
"Unlock Detoxo" and also accepts your **device PIN, pattern or password** as a
fallback — so you have three ways in: Detoxo's PIN, a fingerprint or face, or
your device credential.

### If you forget your PIN

There is **no reset**, by design. Your PIN is hashed and stored on your phone
only — there's no account, no server and no support code behind it. Any code the
app could accept would be a bypass available to anyone holding your phone.

Tapping **Forgot PIN?** on the lock screen says exactly that, and names the one
real escape hatch: **uninstall Detoxo and install it again**, which clears the
PIN along with your settings, blocklists and counts. If uninstall protection is
on, turn it off first in *Settings → Security → Device admin apps*.

### A note on lockouts

Too many wrong tries triggers a cooldown that gets longer the more you miss (from
30 seconds up to 24 hours after many failures). The cooldown sticks even if you
force-quit the app — and it's tied to the phone's internal uptime clock, so
changing the date or time in Settings doesn't skip the wait either. Guessing
isn't a shortcut.

---

## 8. The reel counter (bubble + home-screen widget)

Detoxo counts the short videos you actually watch — Reels, Shorts, and other
infinite-feed clips — so the habit becomes visible. It's **on by default** and
runs **independently of blocking**: it keeps counting even while blocking is off,
paused, or the app is one you didn't block. A video only counts once you've
**stopped on it for about a second**, and the same reel never counts twice — quick
scroll-bys, half-swipes and scrolling the comments don't inflate the number.

The counter's controls live on the **Appearance** screen — open it from the menu
(or **Settings → Appearance**) to turn counting on/off, toggle the bubble, and
customize both surfaces. To see today's and all-time counts with a per-app
breakdown, open **Activity → Events**; for your whole-phone screen time, see
**Activity → Insights** (§15).

### Turn the pieces on/off

On the **Appearance** screen, under **Reel counter**:

- **Count short videos** — the master on/off for the whole counter. With it
  off, Detoxo says so wherever a number would otherwise mislead: the
  **Activity** card explains that counting is off, and the home screen's
  screen-time ring reads "Counting off — screen time not measured" instead of a
  reassuring zero (and your "days under your limit" streak doesn't advance on an
  unmeasured day).
- The **Bubble** and **Home widget** each appear as a card with a large live
  preview. The **Bubble** card has its own on/off switch; tap either card's preview
  to open its editor (available once the relevant switch — and counting — is on).
- If the bubble is switched on but Android's **Display over other apps**
  permission is missing, the Bubble card shows a warning — *Needs "Display over
  other apps" — tap to allow* — and tapping it opens the setting. The warning
  clears by itself when you come back with the permission granted.

### The floating bubble

A small draggable bubble that shows your live count and pops each time you watch
another reel.

- It appears while you're on a reel and tucks away when you leave.
- **During One Reel / Unblock it becomes an unlock countdown.** While one of those
  sessions is live, the bubble swaps today's total for a teal "**N left**" badge —
  how many reels you have left to watch — ticking down as you scroll. When the
  session ends (or you switch back to **Block All** or **Conscious**), the bubble
  **automatically returns to showing today's total reel count**. This only appears
  if the counter bubble is enabled, and only while you're actually on a reel.
- **Drag** it anywhere — it snaps to the nearest side of the screen and remembers
  where you put it.
- **Tap** behavior depends on the **Show time on tap** setting (on by default):
  - **On** — a **single tap** briefly flips the bubble to today's **watch time**
    shown as a running clock (`45s`, `3:05`, or `1:23:45`), then back to the
    count; a **double tap** opens Detoxo.
  - **Off** — a **single tap** opens Detoxo (the classic behavior).
- The bubble needs the **Display over apps** permission (from §2); without it,
  counting still works, only the bubble is hidden.

### The home-screen widget

A 2×2 widget for your home screen showing today's count, a "reels today" caption,
and your all-time total.

1. On the **Appearance** screen, open **Home widget** and tap
   **Add to home screen**.
2. Confirm the placement your launcher offers.

The widget updates itself as you scroll — you don't need to open Detoxo to keep it
current — and rolls over to the new day on its own (within about 15 minutes of
midnight, even if you haven't watched anything yet).

### Make it yours (appearance)

Both surfaces are customizable from the **Appearance** screen — each is shown as a
live preview of your current style; tap it to open the editor:

- **Bubble style** — pick a look (**Glass orb**, **Usage ring**, **Emoji mood**,
  **Minimal pill**), and adjust size, text size, spacing, transparency, whether it
  shows a caption, and **Show time on tap** (tap the bubble to peek at today's
  watch time). A live preview and a **Preview count** slider let you see how it
  looks as the number climbs.
- **Home widget** — pick a background, light/dark/system **theme**, a **density**,
  which lines to show (today / caption / all-time), and whether the color shifts as
  your count grows.
- **Block screen** — the full-screen card shown when something is blocked (§3).
  The card on the Appearance screen carries its own **on/off switch** (off →
  blocks fall back to a short toast) and a live preview; tap it to pick a
  **background**, a light/dark/system **theme**, whether it shows **today's reel
  count** and **times opened today** (the latter needs the Usage access
  permission), whether its accent shifts with your usage, and — under
  **Friction** — whether **Back to the app** waits five seconds before it
  unlocks. **Try it on your phone**
  raises the real card over the editor so you can see exactly what a block looks
  like. Like the bubble, it needs "Display over other apps" — the card says so if
  the permission is missing.

Changes preview instantly and apply to the live bubble, pinned widget and block
screen as you edit.

---

## 9. Settings

Open **Settings** from the top bar or menu. It's grouped into:

**Protection**

- **Daily limit** — jumps to the daily-cap screen (§6).
- *(A **Privacy** group sits just below Protection — see §13 Protected apps.)*
- **When a reel is detected** — choose what blocking actually does:
  - **Press back** — exits the reel (recommended).
  - **Block screen** — exits the reel and shows the full-screen block screen with
    a way back (needs "Display over other apps"; Detoxo opens Android's screen if
    it's missing, and the row underneath says so until you allow it — until then
    the reel still closes and a short toast names the block). With any other mode
    the card only appears when your daily limit is used up, a schedule kicks in,
    or your Conscious bank runs dry.
  - **Close the app** — force-closes the offending app.
  - **Lock app** — hides the app behind your PIN, like an app locker (requires a
    PIN; Detoxo sends you to PIN setup if you pick this without one).
- **Blocking active** — the master switch for all detection. Turning it *off* asks
  for your PIN (when the Settings scope is protected).
- **Vibrate on block** — a small buzz each time a reel is blocked.

**Security**

- **PIN lock** and **PIN settings** (§7).
- **Permissions** — a quick status summary that opens the full grant list (§2).

**General**

- **Appearance** — opens the Appearance screen: choose a **Theme** (**Light** or
  **Dark**, or **Match system** to follow your device — the default), a
  a **Background** — the options are theme-specific, so Dark and Light each keep
  their own pick (Dark: Midnight, Twilight, Nebula, Magenta, Frost, Prism; Light:
  Aurora plus Sky, Dawn, Blossom, Sunrise, Pastel). The chosen background also
  sets the app's **accent colour**, so buttons, switches and highlights harmonise
  with whatever is behind the glass. Manage the **reel counter** here too
  (counting, the bubble, bubble style and the home widget) and the **block
  screen** (its on/off switch and look — §8). Everything previews live.
- **Feedback button** — show a quick feedback button in every top bar.

> Replaying the walkthrough now lives in **Help & support → Feature tutorials**
> (see §11), not in Settings.

**Reset**

- **Reset app data** — wipes your settings, blocklists, limits and PIN and
  restarts onboarding. It's protected by your PIN and asks for confirmation
  because it can't be undone.

---

## 10. Sending feedback

Found a bug or have an idea? Tap the **feedback** button in the top bar (enable it
via **Settings → Feedback button** if you don't see it).

1. Detoxo captures a **screenshot** of the current screen, which you can annotate.
2. Pick a category — **Bug**, **Suggestion**, or **Other**.
3. For suggestions and general feedback, optionally give a star **rating** (bug
   reports skip the rating).
4. Type your message and tap **Send feedback**.

Detoxo opens your device's email app with everything pre-filled — addressed to
**errorxperts@gmail.com**, with the screenshot attached and some app/device details
added to help us reproduce the issue. You just hit send. If no email app is set
up, Detoxo shows the support address so you can reach out manually.

---

## 11. Help & support

Open the menu (top-right) and tap **Help & support** to reach a small hub,
grouped into **Get help**, **Learn & share**, and **Legal**:

- **Report an issue** — opens a short dialog that explains how the feedback
  button works and lets you switch it on (so it appears in every top bar). Tap
  **Report a bug now** to capture the current screen right away, draw on it,
  pick **Bug** or **Suggestion**, and send it to us.
- **FAQ** — a searchable list of common questions grouped by topic (setup,
  blocking & plans, the reel counter, privacy, and more). Type in the search box
  to filter; tap a question to expand its answer.
- **Feature tutorials** — replay the guided tours:
  - **Dashboard tour** — the same welcome walkthrough of the home screen
    (this is where it lives now, having moved out of Settings). It walks you through
    all five blocking modes — **Block All**, **Conscious**, **Pause**, **One Reel**,
    and **Unblock** — plus the **App** and **Web** blockers.
  - **Feedback button** — a quick, one-step highlight that turns the top-bar
    feedback button on (if it's off) and points out where it is and what it does.
- **Share an idea** — a simple box to tell us what would make Detoxo better.
  Type your idea and tap **Send idea**; Detoxo opens your email app pre-filled
  and addressed to **errorxperts@gmail.com** — you just hit send.
- **Privacy Policy** and **Terms & Conditions** — open our Privacy Policy and
  Terms right inside the app, so you can read them without leaving Detoxo.

The first four route to the same support inbox as the feedback button (§10),
so use whichever is handiest.

---

## 12. Keeping the app up to date

Detoxo checks for a newer version on the Play Store when you open the app, and if
one is available it shows a tidy **Update available** card: the new version number,
what's new (when the store provides it), and two choices — **Update now** (opens
the Play Store listing) or **Later**. You can also tap **Skip this version** to stop
being reminded about that particular update.

You can check any time yourself: open **Settings** and tap the **app-version card**
at the bottom (the one showing "Detoxo v…"). If a newer version is available it
shows a compact **Update** button right there; if you're already on the newest
version, Detoxo just tells you you're up to date.

Occasionally an update is **required** (for example, an important fix). In that case
the card can't be dismissed — the only option is **Update now** — so everyone stays
on a safe, working version. This only happens on Android; on iPhone the app is a
preview and doesn't check for updates.

---

## 13. Protected apps: Detoxo steps aside for your private apps

> **Protected applications**
>
> Detoxo automatically pauses its monitoring when you open protected
> applications such as banking, payment, identity, and password-manager apps.
>
> Your protected apps are never interrupted by Detoxo interventions.

Open **Settings → Privacy → Protected apps**. While a protected app is on
screen, Detoxo does **nothing at all** — no counting, no blocking, no bubble,
no reading what's on screen. The moment you leave it, protection resumes on its
own. You never have to toggle anything.

**Automatic, always.** Well-known sensitive apps — banks like HDFC or SBI's
YONO, UPI apps like Google Pay and PhonePe, DigiLocker, password managers,
authenticators and more — are protected automatically and **permanently**.
There is nothing to set up and nothing to get wrong: they can't be switched
off or removed, and one you install *later* is covered the moment it lands on
your phone. The screen lists them under **Auto-protected** so you can see
exactly what's covered.

**Adding your own.** Tap **Add app** and pick straight from a list of the apps
on your phone — search by name, select one or several, done. Apps that are
already covered show a small label ("Auto-protected" or "Protected") so you
can't add them twice, and apps you've blocked show "Blocked" — an app can be
protected *or* blocked, never both; remove it from one list to add it to the
other. (The same rule appears in **Block apps**: protected apps — including
the always-on sensitive ones — can't be blocked.) If an app doesn't appear in
the list (some work-profile apps hide themselves), **"Can't find it? Add
manually"** lets you enter its name and package id (it's in the app's Play
Store URL) — Detoxo checks the id's shape and tells you if it can't be right,
so a typo never leaves a bank looking protected when it isn't. Just installed
the app? Tap the **refresh** button next to the search box. Your additions
appear under **Your apps** with their real icons, and those you can delete any
time.

**One honest guard-rail:** protection beats blocking — so protecting, say,
Instagram would quietly switch its blocking off. If any app you're protecting
is one Detoxo can block, Detoxo asks for your Settings PIN once for the whole
batch (when you have one), exactly like turning blocking off.

Your protected list never leaves your phone, and Detoxo's diagnostics never
mention these apps — not even that you opened one.

---

## 14. Rules: block on a schedule, or cap your day

The **Rules** card sits on your dashboard right under App Blocker and Web
Blocker. It shows how many rules are blocking right now and what happens next
("Work hours · until 17:00", or "Next: Wind down · Fri 22:00"). Tap it — if you
have no rules yet you'll see **Start from a preset**: one tap on *Work hours*,
*Sleep*, *Dinner* or *Doomscroll budget* opens a rule already filled in, so you
can adjust the hours and save. Nothing is saved until you do.

To build one from scratch, tap **New rule** and pick one of three kinds:

- **Schedule** — block during set hours on the days you choose. Pick the days
  (weekdays are pre-selected), a start and an end time. An end time earlier than
  the start means "overnight": *Fri 22:00 → 06:00* blocks Friday night **and**
  the early hours of Saturday, because that whole night counts as Friday.
- **Daily time limit** — a budget of minutes per day (5 to 240). Once it's
  spent, the apps are blocked until midnight.
- **Open limit** — a number of launches per day (1 to 20). After that many
  opens, the app is blocked until midnight.

Then choose what the rule covers under **Block**: add specific **apps** from the
picker (your protected apps are marked and can't be picked), and — for schedules —
**reel feeds** (Instagram Reels, YouTube Shorts…) and **websites** (popular-site
chips or any address you type). Below those, swipe the two rows of **category**
chips (Short-form video, Social, Games…); **All distracting** picks every
distracting category in one tap, and tapping it again clears them. A schedule can
mix all four; time and open limits work on apps and categories, since Android
only counts time per app. **Strict** and **Lock** sit under the targets, just
above Save.

When a rule is blocking, the app bounces you home (or backs out of the site,
or closes the feed) and the block screen tells you when you get it back:
**"Blocked by a schedule · Unlocks at 5:30 PM"**, or **"Your daily limit is used
up · Resets at midnight."** Each rule has a switch to turn it off without
deleting it, and its row shows where you stand — *Active now*, *22/30 min*,
*3 of 5 opens*, or *Next Mon 09:00*. Tap a row to edit or delete it.

Good to know:

- **A Pause lifts your rules**, just like it lifts reel blocking — it is your
  break button. Apps locked in **Block apps** stay locked through a Pause.
- **Unless you mark a rule Strict.** Every rule has a **Strict** switch in its
  editor. A strict rule keeps blocking apps and reel feeds *even while Detoxo is
  paused* — for the rules you set precisely because you know you'll want to skip
  them later. Leave it off and the rule behaves as before.
- **Time and open limits need Usage access.** Android counts app time and
  launches; without that permission a limit can't measure anything, and the
  Rules screen offers a button to grant it. Detoxo re-checks your budgets about
  every 15 minutes in the background, so a limit now runs out and starts
  blocking **without you opening the app**.
- **Turning Usage access off won't unlock a limit you've already used up.** It
  stops new limits from being measured, but a block that's already up stays up
  for the rest of the day.
- Schedules are planned a week ahead, so they keep firing even if you don't
  open Detoxo for days.
- You can keep up to **50 rules**.

---

## 15. Insights: your real screen time

**Activity → Insights** answers the question the reel counter can't: not just how
many short videos you watched, but how your whole day actually went.

The numbers come straight from **Android's own screen-time records** — the same
ones behind Settings → Digital Wellbeing — so they should match what your phone
already tells you, to within a minute or two. Detoxo doesn't estimate them and
doesn't try to be cleverer than your phone.

You'll see:

- **Screen time today**, with yesterday's finished total shown underneath as a
  plain reference ("Yesterday: 4h"). Detoxo deliberately does **not** print a
  percentage: today is still running, so measuring a part-day against a whole
  one would tell you you were doing brilliantly every single morning.
- **How much of it was distracting** — time in apps like short-video, social,
  streaming and games — as a time and as a share of your day.
- **Pickups** — how many times you woke your phone, plus the first and last of
  the day.
- **App switches** — how often your attention jumped from one app to another.
- **Distracting opens** and **reels seen**, so the counter's number sits in
  context.
- **Where it went** — your top apps for the day, longest first. **Tap any of
  them to set a daily limit for that app** — it opens the rule editor already
  filled in, so the moment you notice something is the moment you can act on
  it. Nothing is saved until you choose the hours.

Apps you have marked as **protected** (banking, UPI, password managers) never
appear in this list and are never written down — see §13. Their time is still
part of your total, so the number keeps matching your phone's.

Pull down to refresh. Detoxo recalculates when you open the tab, when you pull,
and when you come back to the app on a new day — there's no background tracking
and nothing runs while you're not looking.

### If you haven't granted Usage access

This screen needs the optional **Usage access** permission. Without it Detoxo
shows a **Grant** card and no numbers at all — deliberately. A screen full of
zeros would look exactly like a genuinely quiet day, and Detoxo would rather show
you nothing than something wrong. Tap **Grant** to open the Android setting; come
back and the numbers appear.

If Detoxo simply couldn't read your screen time (a hiccup rather than a refusal),
you'll get a neutral **Checking…** card with a **Retry** button that tries
again.

### A few honest caveats

- These figures count an app as "in use" whenever it's on screen, even if you
  weren't touching it. That's how Android counts it too.
- **History starts the day you first open this screen.** Android only keeps about
  a week of detailed records, so Detoxo can fill in yesterday but not last month.
  From here on it keeps the last 90 days.
- Per-app usage is **only ever stored on your device** and is never uploaded to
  Detoxo or anyone else. One caveat worth stating plainly: Detoxo's local data
  is currently included in Android's own app backup, so if you have Google
  backup switched on it may be copied to your Google account like any other
  app's data. Excluding it is planned.
- It's **free**. There's no paywall on knowing how you spend your own time.

---

## 16. Notification silence: stop a locked app calling you back

Blocking an app only solves half the problem. The other half is the app *reaching out* —
"3 new reels from people you follow" lands on your lock screen, you tap it, Detoxo bounces
you out, and the notification is still sitting there to tap again.

**Settings → Privacy → Notification silence** closes that loop. While it's on, an app you've
locked in the App blocker — or one an active rule is currently blocking — simply doesn't
notify you. No sound, no banner, nothing in the shade. The moment the block lifts (your
schedule window ends, your limit resets at midnight, you start a Pause, or you turn the
switch off), its notifications come back on their own. Nothing is deleted — the app just
stops interrupting you while it's off limits.

It's **off by default** and needs one extra permission, *Notification access*, which Detoxo
explains in full before sending you to Android's screen for it. Two things worth knowing:

- **Messages and calls always come through.** Detoxo silences the feed, not the person — a
  DM, a call, an email, an alarm or a calendar reminder reaches you even from an app that's
  locked. It's the same idea as the rest of Detoxo: you keep the app, you lose the
  bottomless part.
- **Android has no "just these apps" option here.** Granting notification access technically
  exposes every notification on your phone. Detoxo reads two things — *which app sent it*
  and *whether the app marked it as a message, call or alarm* — and never the title, the
  text, the sender or the images. Nothing is saved, logged, or sent anywhere. Turn the
  switch off and Detoxo stops receiving notifications altogether, not just ignoring them.
- **Your protected apps are never touched** (§13). A banking or password app keeps notifying
  you no matter what else is switched on.

Detoxo also nudges you toward it: once you've locked your first app in the App blocker,
that screen points out that locked apps can still notify you, with a shortcut to the switch.

One thing to know: an app that doesn't label its notifications at all has everything
silenced while it's blocked. Most big apps label messages correctly; a few don't.

---

## 17. Soft nudge: a word, not a wall

Everything else in Detoxo is a yes or a no. That's right for reels — there's no such thing as
"a little bit" of an infinite feed — but it's wrong for the app you *do* want to keep, just
less of. Block it and you'll turn the block off within a week.

**Settings → Protection → Soft nudge** is the setting in between. Nothing is blocked. Open a
distracting app and it opens, normally, like any other. Stay in it and after five minutes a
small card slides up from the bottom: *Instagram · 5 min. Still scrolling. Good time to stop?*

That's all it does. It doesn't close the app, press back, or take over your screen — you can
keep scrolling straight past it, because touches anywhere outside the card go to the app
underneath. It disappears on its own after six seconds, or the moment you tap it.

Stay longer and it comes back at ten minutes, and at fifteen. Leave the app for a minute and
the clock resets — come back and you start from zero.

Worth knowing:

- **It's five minutes *in one sitting*, not five minutes today.** Two four-minute visits won't
  nudge you. If what you want is "tell me once I've spent 30 minutes today", that's a
  different feature and Detoxo already has it — set a **daily limit** in Rules (§14).
- **It stops after four cards per app per day**, so it can't turn into background noise. You
  can change that, and the five minutes, in the same place.
- **You choose nothing app by app.** Detoxo already knows which apps are the distracting
  ones, and nudges those. Your protected apps (§13) are never nudged, and neither is anything
  Detoxo classes as productive.
- **It works even with blocking switched off**, because it isn't blocking — it's just telling
  you the time. And it never appears on top of a block screen: one interruption per moment.

It's off until you turn it on, and it needs the same "display over other apps" permission the
reel counter bubble uses. If that permission isn't granted, the nudge just stays quiet.

## 18. Let yourself in for a bit — and lock the rules you mean

Two things arrived together, because either one alone makes the app worse.

### "Unblock Instagram for 15 minutes"

Until now every way out of Detoxo was all-or-nothing. Need Instagram for two minutes to answer
one message? Your only option was to lift protection on **everything** — reels, every other app,
every blocked site — and hope you remembered to put it back.

Now you can free **one thing**. Tap the timer button on the blocked app's row (or **Allow for a
while** right on the
block screen itself), pick 5, 15, 30 or 60 minutes, and that one app — or that one feed, or that
one site — opens. Everything else stays exactly as protected as it was.

- **It ends by itself.** Detoxo puts the block back when the time is up, even if you never open
  the app again, and even if your phone restarts in the middle. Moving your phone's clock back
  won't buy you extra time.
- **Done early? Tap it again.** "Resume" gives protection back straight away instead of waiting
  out the clock.
- **You never leave the app to do it.** The block screen's **Allow for a while** opens the
  durations right there — no switching to Detoxo, no PIN, no round trip.
- **One place lists what's open.** The home screen shows an *Allowed right now* card while
  anything is, with a Resume button beside each one. It disappears when nothing is.
- **You can cap how often.** Under **Settings → Protection → Allowances** you can limit yourself
  to 1, 2, 3 or 5 a day. It ships as *Unlimited*, so nothing changes unless you ask for it.
- **The row tells you where you stand** — *Allowed until 5:30 PM* — and stops saying so the
  moment it lapses.
- **A Pause is still a Pause.** It lifts reels and websites the way it always did; it does not
  open a whole-app lock. Unblocking one app is the new, narrower door.
- **Adult sites are never in this.** If you have 18+ blocking on, no unblock reaches it, and
  the button doesn't appear on that screen.

### Locked rules

The other half. Any rule in **Rules** (§14) can be **locked** when you make it — and a locked
rule has no off switch. Not greyed out; gone. You can't disable it, you can't delete it, and a
Pause doesn't lift it — and the parts that would let you quietly gut it are frozen too: you
can't drop apps from it, you can't move its hours to 3 a.m., and you can't drag a 30-minute
limit up to four hours. You can still rename it, and you can always make it *cover more*.

Detoxo asks once before you do it, in plain words, because it means it.

**"Cover every distracting app"** is worth knowing about: a lock that only covers the apps you
listed on Tuesday is defeated by installing a new one on Wednesday. Turn this on and the rule
holds over every app Detoxo knows to be distracting, including ones you haven't installed yet.

### The way through: an override

A lock you can never escape is a lock you escape by uninstalling the app, so there's an honest
door — it just costs something. You get **two overrides a week**. Spending one means naming a
reason (feeling unwell, medical appointment, family, your schedule changed, you set the rule up
wrong, or something else) and choosing how long, up to an hour.

Then that **one rule** steps aside for exactly that long. Not your other rules, not your app
blocks, not anything else — and it comes back on time whether or not Detoxo is running. The rule
shows *Lifted to 5:30 PM* while it's open.

If you're out of overrides, Detoxo tells you when the next one arrives. And if the rule isn't
actually blocking right now — a schedule that's closed, a daily limit you haven't spent — Detoxo
won't let you burn one: it says so instead, because you'd be paying for a door that's already
open. There's no PIN on top of any of this either: the quota *is* the friction, and stacking two
gates on one decision just annoys you twice.

**The one thing to be clear about before you lock something:** there is no unlock. If you also
have uninstall protection on, the only way to remove a locked rule is **Settings → Reset app
data** (which clears everything Detoxo has stored), or turning Detoxo's accessibility permission
off in Android Settings. That's the deal, and it's the point.

---

## Related

- Engineering deep-dives (for the curious): [../code_docs/05-plans-pause-conscious.md](../code_docs/05-plans-pause-conscious.md),
  [../code_docs/06-app-and-web-blocker.md](../code_docs/06-app-and-web-blocker.md),
  [../code_docs/07-daily-limit-scheduler.md](../code_docs/07-daily-limit-scheduler.md),
  [../code_docs/27-rules-engine.md](../code_docs/27-rules-engine.md),
  [../code_docs/08-pin-lock-recovery.md](../code_docs/08-pin-lock-recovery.md),
  [../code_docs/13-onboarding-permissions.md](../code_docs/13-onboarding-permissions.md),
  [../code_docs/17-content-counter.md](../code_docs/17-content-counter.md),
  [../code_docs/28-insights.md](../code_docs/28-insights.md),
  [../code_docs/20-help-support.md](../code_docs/20-help-support.md).
- Other user guides: [Product Overview](01-product-overview.md) ·
  [Permissions Explained](03-permissions-explained.md) · [FAQs](04-faqs.md).
