# What's in version 2.2

This page is written for someone who has never written a line of code.
No jargon, or where a technical word is unavoidable, it gets explained.

Version 1 was an early experiment. Version 2 was a complete rebuild, and
it's the one that actually lives on the Kindle and gets used every day.
Version 2.1 added an optional screen-lock PIN and the ability to lock the
screen from your phone. **Version 2.2 adds a whole new screen: Daily, a
recurring habit checklist** - see "Daily" further down. Everything else
on this page describes what version 2 (and 2.1) already did.

---

## What this thing is

An old Kindle, sitting on a desk, showing a dashboard instead of a book.
It shows the time, today's tasks, what you're learning, your daily
habits, and how much of your Claude usage allowance you've spent. You
tap the screen to tick things off, and you add new things from your
phone using Telegram.

Two important things about how it works:

- **Nothing goes to the internet or to any company's servers**, with one
  optional exception you have to turn on yourself: daily-habit history
  can sync to a Google Sheet you own, if you set that up (see "Daily"
  below). Skip it, and the "brain" of this runs entirely on your own
  laptop. The Kindle just talks to your laptop over your home WiFi. If
  your laptop is off, the Kindle simply says `OFFLINE` and waits.
- **Your Kindle is still a Kindle.** The dashboard only runs when you
  start it, and stopping it gives you your normal reading device back.
  You are not giving up your e-reader to get a dashboard.

---

## The screens

### Today

The main screen.

- **A big clock and the date** at the top.
- **A battery indicator** in the top-right corner, showing the Kindle's
  own charge as a little battery symbol that fills up, plus a percentage.
  At 20% or below, the percentage flips to white-on-black so it catches
  your eye before the Kindle dies on you.
- **A connection light** that says `ONLINE`, `OFFLINE` or `CONNECTING`,
  so you always know whether what you're looking at is up to date.
- **Your task list**, four at a time. Tap a task to tick it off - ticked
  tasks drop to the bottom of the list instead of vanishing, so you can
  see what you got done.
- **A "+ Add Task" button**, which brings up a keyboard on the screen.
- **Numbered pages** if you have more tasks than fit. Tap a page number,
  tap the arrows, or just **swipe left and right across the list** like
  turning a page in a book.
- **A "Claude usage" card**, explained on its own below.
- **Two buttons at the bottom**, explained under "Getting out of trouble".

### Learning

A second screen, reached by tapping "Learning" at the bottom.

It tracks two kinds of thing, each with a progress bar:

- **Courses** - you tell it you're 40% through, it shows 40%.
- **Books** - you tell it you're on page 120 of 300, and it works the
  percentage out for you.

This screen is deliberately **read-only**: you look at it, you don't edit
it. The reason is honest and simple - changing any of these numbers
requires typing a *number*, and the Kindle's on-screen keyboard has
letters only, no digits at all. Rather than pretend, all changes are made
from Telegram on your phone, where you have a real keyboard.

### Daily (new in 2.2)

A third screen, reached by tapping "Daily" at the bottom - a recurring
checklist for things you want to do *every day*, laid out like a
calendar day view: a time, a name, and a checkbox, always in time order
from earliest to latest.

- **Tap a habit to tick it off, right on the Kindle** - this one's
  different from Learning: no phone needed for the everyday part.
  Ticked-off items don't jump to the bottom like your tasks do, though -
  they stay in their time slot, since the point of this screen is
  seeing what your whole day looks like, not a shrinking to-do list.
- **Delete works the same two-tap way as your task list**: tap the "x"
  once to arm it, tap it again within a few seconds to confirm.
- **Adding a new habit is done from Telegram**, the same reason as
  Learning - you need to type a time, and the Kindle's on-screen
  keyboard has no number keys. Send `/daily 7:00 AM Meditate` (or
  24-hour style, `/daily 19:00 Dinner prep` - it converts either way to
  the same 12-hour display).
- **Every day at midnight, all the checkmarks clear** and a new day
  starts - but the list of habits itself stays exactly as you built it,
  forever, until you delete something.
- **Optional: a running history in a Google Sheet you own.** If you
  want to look back at streaks over weeks or months, there's an
  entirely optional setup (`docs/GOOGLE_SHEETS_SETUP.md`, no coding
  needed, about 10–15 minutes) that copies each day's results into a
  spreadsheet automatically. Skip it and nothing else changes - the
  Daily screen works exactly the same either way, this is purely for
  people who want the extra history.

### Home

One more tab is visible at the bottom but isn't built yet. It's greyed
out and says "coming soon" if you tap it, rather than looking broken.

---

## The Claude usage card

Shows how much of your current Claude session allowance you've used, as a
percentage and a bar, plus when it resets.

**Tap anywhere on that card to refresh it.** The whole card is the
button - the label, the number, the bar, all of it - not just the small
circular arrow in the corner. (It used to be only that little icon, which
was fiddly to hit accurately on a touchscreen this old.)

If you tap it twice in quick succession it'll tell you to wait a moment,
rather than silently doing nothing.

---

## Adding things from your phone (Telegram)

You talk to a private Telegram bot that only you can use. Whatever you
send appears on the Kindle within a second, without touching the Kindle.

| You send | What happens |
|---|---|
| `/add buy milk` | Adds a task |
| `/list` | Shows everything currently tracked, with its number |
| `/done 3` | Marks task 3 finished |
| `/delete 3` | Deletes task 3 |
| `/course Spanish` | Starts tracking a course |
| `/book Dune 412` | Starts tracking a book of 412 pages |
| `/percent L1 40` | Sets that course to 40% |
| `/page L1 120` | Records that you're on page 120 |
| `/total L1 400` | Corrects a book's page count |
| `/daily 7:00 AM Meditate` | Adds a daily habit - 24-hour times work too, e.g. `/daily 19:00 Dinner prep` |
| `/dailyhistory` | Shows the last 7 days for each daily habit |
| `/dailysync` | Forces an immediate push to Google Sheets, if you've set that up |
| `/setpin 1234` | Sets (or changes) the screen-lock PIN - `/setpin off` removes it |
| `/lock` | Locks the Kindle's screen right now |
| `/help` | Lists all of the above |

Tasks are plain numbers (`3`); courses and books get an **L** in front
(`L1`, `L2`); daily habits get a **D** (`D1`, `D2`). `/list` shows you
which is which. That distinction isn't fussiness - `/done` and `/delete`
work across all three lists, so without it, deleting task 3 on a day
when you have no task 3 could have deleted your learning item 3 or your
daily habit 3 instead.

---

## The screen lock, and making the battery last

Press the Kindle's **power button** once and the screen goes blank except
for the word **Locked** in the middle. Press it again and your dashboard
comes straight back, on whatever tab you left it on.

The word matters more than it sounds. A completely blank Kindle looks
exactly like one where the dashboard has crashed. "Locked" tells you
nothing is wrong and one button press brings it back.

**It also locks itself after 15 minutes** if nobody touches it, to save
battery. You can change that time, or switch it off entirely, with one
setting (`auto_lock_idle_ms` - the setup guide shows you where).

While it's locked, the Kindle stops doing almost everything: no clock
updates, no battery checks, no screen refreshes, and taps are ignored so a
dashboard in a bag doesn't tick off your tasks by accident.

### The PIN, and locking from your phone (new in 2.1)

Two small additions on top of the lock above, both optional:

- **A 4-digit PIN.** Send the bot `/setpin 1234` (any 4 digits you like)
  and pressing the power button to unlock no longer brings the dashboard
  straight back - it shows a small number pad on the screen first, and
  only the right 4 digits actually unlock it. Get it wrong and it just
  clears and lets you try again, no penalty. Send `/setpin off` any time
  to remove it and go back to instant unlocking.

  The number pad exists because the dashboard's regular on-screen
  keyboard (used for adding tasks) only has letters, no digits - the same
  reason learning progress is only editable from Telegram. The PIN is
  checked entirely on the Kindle itself, so it still works even if your
  laptop or WiFi happens to be down at the time.

- **`/lock` from Telegram.** Send it and the Kindle locks right now,
  wherever you are - same lock, same PIN if you've set one, as pressing
  the power button yourself. Handy if you walked away and want to be sure
  it's not sitting unlocked.

**On power use generally.** E-ink screens are unusual: keeping an image on
screen costs nothing at all. The battery goes on *changing* the screen and
on the Kindle waking up to think. So version 2 was changed to sleep
between events rather than waking up twice a second to check whether
anything happened. Measured on the actual device, the dashboard now uses
about **a twelfth** of the processing time it used to while you're using
it, and about **a hundred and seventy-fifth** while the screen is locked.
In plain terms: it went from constantly ticking over to genuinely asleep
until you touch it.

---

## Getting out of trouble

Two buttons sit at the bottom of the Today screen. Exit Dashboard exists
because of a real problem hit during building: it used to be possible to
get into a state where you needed the laptop to fix the Kindle, but the
Kindle was the thing that had stopped listening to the laptop.

- **Exit Dashboard** - asks you to confirm, then restarts the Kindle back
  into normal reading mode.
- **Network Info** - shows a popup with the Kindle's current wifi
  network name, IP address, gateway, and a few other connection details,
  for the times you need to SSH in and don't already know the current
  address (it changes). Disappears on its own after 10 seconds, or tap
  outside the popup to close it right away. (Version 2.2 replaces the
  old "Restart SSH" button here - dropbear, the Kindle's SSH server, has
  proven reliable enough not to need a manual restart from this screen,
  and since the Kindle reconnects to a previously-used wifi network on
  its own when you switch networks, checking the current address is what
  this spot actually gets used for.)

Day to day you don't need either. Starting and stopping the dashboard is
two double-clickable files on the laptop: `Start_Dashboard.bat` and
`Stop_Dashboard.bat`.

---

## Things that quietly work now, that didn't before

These are fixes rather than features, but they're the difference between
something you can rely on and something you can't:

- **Moving house, changing WiFi, or a new router doesn't break it.** The
  laptop works out its own address every time it starts the dashboard and
  tells the Kindle. Nothing to edit by hand.
- **The Kindle no longer restarts itself when you start the dashboard.**
  It used to, reliably, and the cause turned out to be a safety mechanism
  in the Kindle's own factory software reacting to how the dashboard took
  over the screen. It now asks politely instead of forcing its way in.
- **The dashboard no longer drops offline after a few seconds** on some
  WiFi networks. The Kindle's WiFi chip was putting itself to sleep
  mid-conversation; it's now told not to while the dashboard is running.
- **If your laptop goes to sleep, the Kindle reconnects on its own** when
  it comes back, waiting a little longer between attempts each time
  instead of hammering the network.
- **It tells you when it has lost touch with your laptop.** There's a
  situation where the link between the two dies without either side being
  told - most often when your router hands the laptop a different address
  while the dashboard is running. The Kindle used to carry on as if
  nothing had happened: still showing ONLINE, still accepting taps, and
  quietly throwing every one of them away. Now it checks in with the
  laptop every 30 seconds, and if it hears nothing back for a minute and a
  half it says OFFLINE and starts trying to reconnect.
- **And then it finds your laptop again by itself.** Your laptop quietly
  announces its address on your home network every few seconds, and the
  Kindle listens for that. So when the router changes your laptop's
  address - moving house, a new router, or just your laptop reconnecting
  to WiFi - the dashboard notices within about a minute and a half,
  re-finds the laptop within a second, and carries on. No restarting
  anything. This used to be the one failure you had to fix by hand.

  You can turn it off (`discovery_enabled = false` on the Kindle,
  `DISCOVERY_ENABLED=0` on the laptop). Worth knowing if you're deciding:
  those announcements aren't password-protected, so in principle another
  device on your home network could imitate one and point the dashboard
  somewhere else. The Kindle refuses any address outside your own home
  network, and nothing else in this project is password-protected either
  - but it's your network and your call.
- **The dashboard stays responsive while it's trying to reconnect.** A
  long-standing bug meant that whenever the Kindle tried to reach a laptop
  that wasn't there, the whole dashboard froze for the duration - taps,
  the power button, the clock, everything. Fixed.
- **Your tasks survive a crash.** If the file holding them is ever
  damaged, it's kept as a backup copy rather than thrown away.

---

## An optional extra

There's a `lockscreen` folder for replacing the picture the Kindle shows
when it's asleep in normal reading mode with your own text. It's entirely
optional and separate from everything above.

---

## Where to start

If you're setting this up for the first time, read
**`docs/LAUNCH_GUIDE.md`**. It's the one start-to-finish walkthrough and
it assumes no technical knowledge. Everything else in this repository is
detail you can reach for later, if ever.
