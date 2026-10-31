# Focus (3.4.0)

Focus sessions with breaks, a menu bar countdown and a log (Session, Flow, Raycast Focus); hiding distracting
apps while you focus; quitting apps you leave open in the background (Quitter), including a memory saver for
8 GB Macs; optional break reminders; and a keyboard language per app (Input Source Pro). Everything is on the
**Focus** page in the sidebar's Productivity section.

## Focus sessions

Start a session from any of these:

- **Start Focus** on the Focus page (⌘↩ while the page is open).
- **Start Focus · 25 min** in the menu bar menu (Productivity section). While a session runs the same item reads
  **Stop Focus · 18:22 left**.
- **Focus Session** in Workspace's quick actions.
- A shortcut you set in Settings › Shortcuts › Productivity › Start or Stop Focus Session (none by default).

The same command ends a running session. On the page you can also **Pause**, **Resume**, **Skip to Break** (ends
the focus early and starts the break) or **Skip Break** (starts the next focus now), and **Stop**.

| Choice | What it does |
|---|---|
| Length: 25/5, 50/10, 90/15 | Focus and break minutes (Pomodoro, a 50-minute block, a 90-minute deep-work block). |
| Custom… | Your own focus, break and long-break minutes. A running focus keeps its length; the next ones use the new lengths. |
| Breaks | A break follows each focus. Off: a session is one focus. |
| Long breaks | A long break after every N sessions (2–8, default 4). The count starts again after a long break, or after two hours without a focus. |
| Start the next focus by itself | After a break the next focus starts at once. Off: Focus waits for you. |
| Sound at the end | Played when a focus or break ends (Glass by default, or None). |
| Countdown in the menu bar | A separate menu bar item (not AOM's icon) shows the time left only while a session runs, and goes away when it ends. Its menu has Pause/Resume, Skip, Stop Focus and Open Focus. |

When a focus or break ends you hear the sound and see a short HUD ("Focus Complete · Take a 5 min break").

**Sleep.** Time keeps passing while the Mac sleeps. If the focus ended while the lid was closed, it counts as a
completed session at the time it ended, the break runs on schedule, and when you open the Mac you see one quiet
note ("Break Ended") without a sound. A focus is never started in the past: after a long sleep the session simply
ends. If All of MacOS quits during a session, it continues where the clock is when it starts again.

**Log.** The **Today** card shows sessions and focused minutes today, this week (the calendar's first weekday),
and a chart of the last seven days. A session counts when a focus runs to its end; a stopped or skipped focus
keeps its minutes but is not a session. Focus shorter than a minute is not logged. A focus that crosses midnight
gives its minutes to both days.

## During a focus

| Option | What it does |
|---|---|
| Hide distracting apps | Hides the apps you list when a focus starts, and again whenever one of them comes forward during the focus, with a short HUD ("Focus: 18 min left"). Breaks are free; nothing is hidden while paused or while AOM is paused. |
| Mute sound | Mutes the output when a focus starts and turns it back on when it ends, only if Focus muted it, on the same device, and it's still muted. |
| Keep the Mac awake | The Mac and display stay awake until the focus ends (Keep Awake). A Keep Awake you turned on yourself is left alone. |
| At the start, run / At the end, run | Runs a shortcut from the Shortcuts app when a focus starts or ends. |

**About macOS Focus.** macOS gives apps no way to turn a Focus such as Do Not Disturb on or off. To get that, make
a shortcut in the Shortcuts app with its **Set Focus** action (for example "Turn Do Not Disturb On" and another
for Off) and choose them here. The list comes from `/usr/bin/shortcuts list`; use the refresh button after making
a new one. If a shortcut fails, the page and Workspace say why, and the activity log keeps it.

## Idle apps and memory

Turn on **Hide or quit idle apps**, then **Add App** for apps you tend to leave open (chat, mail, music). For each
app choose **Hide After** and **Quit After** a number of minutes, or Never. An app is idle while it is not the
app in front; using it starts its time again. Each row shows the live idle time, its memory (the app with its
child processes, like Activity Monitor's Memory column) and what happens next ("quits in 18 min").

Never touched, whatever the rules say:

- Finder and All of MacOS
- the app in front
- apps playing audio and apps recording audio (from Core Audio's process objects, the same source as the audio
  mixer; macOS 14.2 or later, earlier systems leave every app alone)
- apps AOM is paused for, and every app while AOM is paused (Pause AOM or Automation Paused)

Quitting asks the app to quit the normal way, so an app with unsaved changes asks to save. Nothing is force
quit. An app that is still open a minute later is noted in the log and left alone until you use it. For two
minutes after the Mac wakes or the screen unlocks, nothing is hidden or quit.

**Memory.** The Memory card shows the memory pressure (Normal, Warning, Critical: Activity Monitor's green,
yellow and red), the swap in use and how much memory quitting idle apps freed today. With **When memory runs low,
quit idle apps first** on, a yellow or red pressure quits the idlest listed app first (only apps idle at least
5 minutes, adjustable), waits 15 seconds for memory to come back, and goes on until pressure is normal, five
apps were quit, or no app qualifies; then it pauses for 10 minutes. A rule can opt out with **Quit Early When
Memory Runs Low** in its ⋯ menu.

**Quit Idle Apps Now** (page and menu bar) lists the apps it would quit with their memory and asks first. It
works while AOM is paused, because you asked for it; the other protections still apply.

## Break reminders

- **Eye breaks**: every 20 minutes at the screen, a HUD reminds you to look about 20 feet away for 20 seconds
  (the 20-20-20 rule).
- **Stand-up reminders**: after 30–90 minutes at the screen (50 by default).

Reminders wait during a focus break and while AOM is paused. Time away from the Mac (five minutes without input,
sleep, a locked screen) counts as a break.

## Input sources by app

Turn on **Switch input sources by app** and add apps with the source they should use, for example Terminal in
ABC and KakaoTalk in 2-Set Korean (**Add Suggestions** adds installed terminals, code editors and KakaoTalk).
When the app comes to the front, Focus selects its source. **Remember the source in other apps** gives every app
without a rule back the source you used there last.

It never switches while a password field has the keyboard (secure input), while AOM is paused, or for an app AOM
is paused for. With Korean, Chinese, Japanese or Vietnamese sources, macOS sometimes shows the new source in the
menu bar while the first keys still type in the old one (a known macOS behaviour of `TISSelectInputSource`);
clicking in the window fixes it. Focus does not use the workarounds other apps use for this (briefly taking the
keyboard focus, or pressing ⌃Space for you).

## Where things are kept

- Options: one setting, `AOMFocusSettings.v1`. Settings › Data › Reset Preferences resets it.
- Lists you make (distracting apps, idle-app rules, input-source rules), the session log, the activity log and a
  running session: `~/Library/Application Support/AllOfMacOS/Focus/` (`lists.json`, `sessions.json`,
  `activity.json`, `state.json`). Reset Preferences does not delete them. The log keeps about a year.

## Cost on an 8 GB Mac

Nothing runs for a feature that is off. While a session runs, one timer ticks once a second (none while paused
or idle). Idle-app rules use app-switch notifications and one timer set for the next threshold, not polling;
the memory-pressure watch is a system notification. Memory is measured only while the Focus page shows it and
just before a quit. Input sources use the app-switch and input-source notifications only.
