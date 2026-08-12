# What's in version 2

This page is written for someone who has never written a line of code.
No jargon, or where a technical word is unavoidable, it gets explained.

Version 1 was an early experiment. Version 2 is a complete rebuild, and
it's the one that actually lives on the Kindle and gets used every day.

---

## What this thing is

An old Kindle, sitting on a desk, showing a dashboard instead of a book.
It shows the time, today's tasks, what you're learning, and how much of
your Claude usage allowance you've spent. You tap the screen to tick
things off, and you add new things from your phone using Telegram.

Two important things about how it works:

- **Nothing goes to the internet or to any company's servers.** The
  "brain" of this runs on your own laptop. The Kindle just talks to your
  laptop over your home WiFi. If your laptop is off, the Kindle simply
  says `OFFLINE` and waits.
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
- **Your task list**, four at a time. Tap a task to tick it off — ticked
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

- **Courses** — you tell it you're 40% through, it shows 40%.
- **Books** — you tell it you're on page 120 of 300, and it works the
  percentage out for you.

This screen is deliberately **read-only**: you look at it, you don't edit
it. The reason is honest and simple — changing any of these numbers
requires typing a *number*, and the Kindle's on-screen keyboard has
letters only, no digits at all. Rather than pretend, all changes are made
from Telegram on your phone, where you have a real keyboard.

### Habits and Home

Two more tabs are visible at the bottom but aren't built yet. They're
greyed out and say "coming soon" if you tap them, rather than looking
broken.

---

## The Claude usage card

Shows how much of your current Claude session allowance you've used, as a
percentage and a bar, plus when it resets.

**Tap anywhere on that card to refresh it.** The whole card is the
button — the label, the number, the bar, all of it — not just the small
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
| `/help` | Lists all of the above |

Tasks are plain numbers (`3`); courses and books get an **L** in front
(`L1`, `L2`). `/list` shows you which is which. That distinction isn't
fussiness — `/done` and `/delete` work on both lists, so without it,
deleting task 3 on a day when you have no task 3 could have deleted your
learning item 3 instead.

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
setting (`auto_lock_idle_ms` — the setup guide shows you where).

While it's locked, the Kindle stops doing almost everything: no clock
updates, no battery checks, no screen refreshes, and taps are ignored so a
dashboard in a bag doesn't tick off your tasks by accident.

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

Two buttons sit at the bottom of the Today screen for when something goes
wrong. Both exist because of a real problem hit during building: it used
to be possible to get into a state where you needed the laptop to fix the
Kindle, but the Kindle was the thing that had stopped listening to the
laptop.

- **Exit Dashboard** — asks you to confirm, then restarts the Kindle back
  into normal reading mode.
- **Restart SSH** — turns the Kindle's remote-connection service back on,
  so your laptop can reach it again.

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
  told — most often when your router hands the laptop a different address
  while the dashboard is running. The Kindle used to carry on as if
  nothing had happened: still showing ONLINE, still accepting taps, and
  quietly throwing every one of them away. Now it checks in with the
  laptop every 30 seconds, and if it hears nothing back for a minute and a
  half it says OFFLINE and starts trying to reconnect. If the laptop was
  just asleep or the WiFi hiccupped, it sorts itself out with no help from
  you. If the laptop's address genuinely changed, it can't guess the new
  one — but the screen now tells you the truth instead of pretending, and
  double-clicking `Start_Dashboard.bat` puts it right.
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
