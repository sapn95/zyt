# zyt

**Work or private: a menu-bar clock that knows which one is running, and a
booking proposal that keeps to the rules.**

One notebook carries both the job and everything else. The employer wants the
hours to the minute, on weekdays, inside a window, in blocks with breaks
between them. The notebook sees a Saturday afternoon in a repository, an
evening in a terminal, and a browser tab that could be either. zyt watches what
is in front, decides whose time it is, keeps the minutes, and at the end of the
week lays them out the way the timesheet wants them, without making a minute
up or letting one go.

It is a [Hammerspoon](https://www.hammerspoon.org) Spoon plus one command.
*Zyt* is Bernese for time.

```text
W                          ← the menu-bar item: work is running
├─ Work                    → pin it, until the next lock
├─ Private
├─ ✓ Auto                  → let the rules decide
├─ ────────────
├─ Today  6h12 work · 0h48 private
├─ Copy this week's report
├─ Show this week's board   → the HTML page, in the browser
├─ ────────────
├─ Open the rules file
├─ Reload the rules
├─ Forget the answers, ask again ▸   → only this one, or all of them
├─ ────────────
└─ Quit zyt
```

## How it decides

Every thirty seconds, and whenever another application comes to the front,
the Spoon looks at the frontmost window and asks the rules, in this order:

1. **A pin.** `Work` or `Private` from the menu, `zyt work` or `zyt private`
   from a shell. It holds until the screen locks.
2. **The application.** Outlook is work. Spotify is not. The `apps` table in
   the rules file says which is which.
3. **The repository, for terminals and editors.** An application marked
   `repo` is classified by the git remote of the repository it is in:
   `github.com` is private, the employer's git host is work. The repository
   comes from the chat in the pane the terminal says is in front
   ([ADR 0012](docs/adr/0012-the-pane-in-front-is-the-chat.md)), from the
   application's own working directory (iTerm2 says over AppleScript), from a
   word in the window title that names a checkout, or from a note a coding
   tool left behind ([ADR 0003](docs/adr/0003-a-terminal-belongs-to-its-remote.md)).
4. **The title.** `Jira` and `Confluence` are work, `GitHub` is not, whatever
   the browser.

   An editor opened on a folder full of checkouts says nothing useful in its
   title by default. VS Code, and editors built on it such as Kiro, can be told
   to name the active file's folder, and then every window of them is
   classified from the repository that folder is in:

   ```json
   "window.title": "${dirty}${activeEditorShort}${separator}${rootName}${separator}${activeFolderLong}"
   ```

5. **Otherwise it asks, once.** A small panel under the menu bar, one row per
   answer: Work, Private, or Don't ask. It stays until you pick one, and a lock
   takes it down. The answer is kept for that repository or that
   application and never asked again; until it is answered, and for a Finder
   window you told it not to ask about, what was already running keeps running
   ([ADR 0002](docs/adr/0002-unknown-is-sticky-not-a-third-class.md),
   [ADR 0009](docs/adr/0009-ask-once-and-remember.md)). An answer that turns out
   wrong is forgotten from the menu, either only for what is in front — the menu
   names it — or all of them at once.

A lock, sleep, or ten minutes without input end the segment, backdated to the
last keystroke so the idle minutes are in no row at all. A call in Teams or
Zoom is exempt, and so is a coding tool working on your behalf: while it keeps
reporting in, you are present, and its repository decides whose time it is
even if the window in front is Spotify. A lock ends that too
([ADR 0005](docs/adr/0005-away-starts-at-the-last-input.md)).

## Coding tools say where they are

A coding assistant works for minutes with nobody typing, in a window that does
not name the repository. So the tool tells zyt: `zyt hook claude-code` on
Claude Code's `UserPromptSubmit` and `PostToolUse` events leaves a note with
the directory of the file the tool touched, or the working directory when
there is none, and its git remote; the Spoon reads it while it is fresh. A
prompt also marks the chat you are talking to, and with several sessions open
in one editor that chat, not whichever session is busy, decides its class
([ADR 0004](docs/adr/0004-a-tool-says-where-it-is-working.md)). Any other tool
can leave the same note with `zyt context <name> <directory>`.

Each session gets a note of its own, so several chats in one editor can be told
apart. When they are all in repositories of the same class, that is the class,
whichever panel you are reading. When they straddle both, nothing on screen can
say which one you are in, because the editor does not expose its panels, so zyt
asks whose time the chat you last typed into is, and the panel names that chat:
Work, Private, Later. The answer belongs to that conversation and holds for as
long as it is the one in front, so each chat is asked about once and a chat you
have answered for is never asked about again. The next new chat in the same
editor is a question of its own, and that is the only thing that brings the
panel back. Typing keeps it away for two minutes, and a panel about an editor
you have left goes on its own. Later buys half an hour of quiet. Forgetting an
answer about a chat is in the menu, under the name the chat goes by
([ADR 0010](docs/adr/0010-which-chat-of-several.md)).

iTerm2 is the exception, because it knows. It gives every shell it opens an id
for the pane it opened it in, the hook writes that id into the note, and it
answers which pane is in front when it is asked. Four chats in four tabs are then
told apart by the terminal itself: switching tabs between an employer repository
and a private one changes the class and asks nothing. Another terminal notes its
pane too and nothing asks it yet, so its chats are told apart by what they work
on, the same as an editor's ([ADR 0012](docs/adr/0012-the-pane-in-front-is-the-chat.md)).

```json
"hooks": {
  "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "zyt hook claude-code" }] }],
  "PostToolUse":      [{ "hooks": [{ "type": "command", "command": "zyt hook claude-code" }] }]
}
```

## The meetings you were not at a keyboard for

An hour in a meeting room is work, and nothing on the screen says so: the
notebook is shut, or open and untouched until the idle rule ends the segment at
the last keystroke. zyt can read the calendar and count that hour.

It reads Microsoft Graph, not Outlook, because Outlook for Mac no longer hands
its live calendar to AppleScript
([ADR 0013](docs/adr/0013-the-calendar-comes-over-graph.md)). It asks for the
start, the end, the all-day flag, the busy status and the answer you gave, and
for nothing else: no subject, no attendees, no location.

The `meetings` block in the rules file turns it on. It needs an app
registration of your own, a single-tenant public client with `Calendars.Read`
consented for you alone:

```json
"meetings": {
  "enabled": true,
  "tenantId": "<your tenant>",
  "clientId": "<your app>",
  "class": "work",
  "statuses": ["busy", "oof", "tentative"],
  "skipSubjects": ["social event", "team event"],
  "minimumSeconds": 300,
  "lookbackHours": 24
}
```

`skipSubjects` is for the hours that are in the diary because people are in the
same room rather than because anybody is working: a team event, a drink, a
social evening. Each entry is text to find inside the subject, case ignored.
The subject is read to make that decision and goes no further: what is handed
on is times and a status, and nothing that says what a meeting was about
reaches the record, the Spoon or the screen. `zyt meetings` says how many it
left out and not which.

`zyt login` signs in once, in the browser, and keeps the refresh token in the
login keychain. `zyt meetings` prints what it can see, which is the way to check
that the sign-in and the scope are right.

From then on it keeps itself in line. A meeting is written as the calendar has
it, the whole of it, whether or not you were at the keyboard through it: both
are true. Two rows over one hour are one hour, because the totals take the union
of what is covered rather than the sum. It leaves out what you declined, what
was cancelled, what says `free` and what lasts the whole day, merges what runs
back to back, and writes nothing into the hour you are in right now.

Every `syncHours` it goes over a whole window, `lookbackDays` back and
`lookaheadDays` forward, and brings the record into line with the calendar:
rows that are missing are written, and rows a meeting left behind when it moved
or was called off are taken out again. Nothing is ever written for time that has
not happened; the window reaches forward so that a meeting which moved can be
recognised there, not so that tomorrow can be booked. Rows the tracker wrote
itself are never touched.

`zyt sync` does the same round by hand, and `zyt sync --all` goes back to the
first row there is, which is how the days before you turned this on get their
hours.

## The week

```console
$ zyt week
Week 2026-W38  14.09. to 20.09.2026

           recorded                              proposal
day        start  end    work   private  break   booking                                booked
Mon 14.09.  08:02  16:42  7h55   0h20     0h45    08:00-13:00, 13:30-17:40               9h10
Tue 15.09.  07:48  15:02  6h04   1h10     1h10    07:45-12:45, 13:15-17:19               9h04
Wed 16.09.  08:31  21:15  8h15   0h00     3h29    08:30-13:30, 14:00-18:10               9h10
Thu 17.09.  08:10  16:40  8h30   0h00     0h00    08:10-13:10, 13:40-17:40               9h00
Fri 18.09.  08:00  19:58  11h23  0h00     0h35    07:37-12:37, 13:07-18:07, 18:37-20:00  11h23
Sat 19.09.  15:20  20:40  5h20   2h00     0h00    moved to the workdays                  -
Sun 20.09.  00:05  00:25  0h20   0h46     0h00    moved to the workdays                  -

recorded 47h47 work, 4h16 private  ·  booked 47h47  ·  left over 0h00
```

The left half is what happened. The right half is what to type into the
timesheet: workdays only, nothing before `earliest` or after `latest`, no
block longer than `maxBlockMinutes`, `breakMinutes` between blocks, and the
first of those breaks inside the `lunch` window, because that break is lunch
and lunch is at midday. Weekend
hours and anything a workday could not hold are dealt out to the workdays with
the fewest hours first; a day keeps its real start where it fits. What finds
no room is printed as the leftover rather than dropped
([ADR 0006](docs/adr/0006-the-proposal-moves-minutes-it-never-makes-them.md)).

A day holds what the window holds: `08:00` to `20:00` with five-hour blocks
and an hour between them is ten hours, so five workdays hold fifty, and a week
of 50h08 leaves eight minutes over. Set `"latest": null` for a day with no
closing time, and the week is booked whole; a block may then end at `24:00`,
which is midnight. The board draws the hours the days actually used rather
than every hour to the end of the clock.

`zyt day` is one day of the same; `--json` on either gives it to a script.

**No private minute is in the booking.** A minute recorded as private is not a
work minute, even when something else says it is: a meeting is written as one
stretch and the keyboard goes on recording underneath it, so a private message
answered in a meeting arrives as both, and work is what is left of it. A
private stretch of `skipPrivateMinutes` or more is kept out of the blocks as
well, so no block stands over it; shorter ones are left alone, because private
time on a workday arrives as slivers and a block cut at every one of them
would be twenty blocks nobody can book
([ADR 0014](docs/adr/0014-a-private-minute-is-not-a-work-minute.md)).

The slivers are still under a block on the clock, and the report says how many
rather than leaving you to trust it:

```text
recorded 50h08 work, 5h26 private  ·  booked 50h00  ·  left over 0h08
none of the private time is booked; 0h58 of it is under a block, in stretches
too short to be laid round
```

The board draws the same thing: the stretches are painted purple on the
booking lane where a block was drawn across them, each one labelled with the
seconds it really lasted, the day's figures name the amount, and `--json`
carries it per day as `privateUnderBooking`.

## The board

```sh
zyt board                                      # this week, written and opened
zyt board 2026-W38                             # another week
zyt board 2026-09-14                           # one day on its own
zyt board --one-week --out ~/Desktop/week.html --no-open
```

The same week, drawn instead of tabulated. Each day gets three lanes on one hour
scale: the hours at the keyboard, work in blue and private in purple; the hours
the calendar accounted for, in teal, because an hour in a meeting is work but
not the same thing to look at; and the blocks the proposal would have you book. Hover a bar and it names its exact
times. The scale covers the hours that may be booked and widens for anything
outside them, so a Sunday evening shows up where it happened.

```text
            07   08   09   10   11   12   13   14   15   16   17   18
Mon 14.09.       ████████████████████▓▓▓▓ ███████████████████     7h50 · 0h45 private
                           ▓▓▓▓▓▓▓▓▓▓                             (in a meeting)
                 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒  ▒▒▒▒▒▒▒▒▒▒▒▒▒▒       08:00–13:00 · 13:30–16:20
```

The links above the heading go back and forward a week. The file holds every
week from the first one with hours in it to the last, and the week asked for
when that is a later one still, one page each, so following a link fetches
nothing and the ends of the run say so instead of offering a link. A day asked
for by date is alone in the file and has no links, and `--one-week` does the same
for a week, which is what to write out when the file is going to somebody else.

One file with a `<style>` in it and nothing else: no script, no font, no
stylesheet, nothing fetched when it opens, and dark mode follows the system
([ADR 0011](docs/adr/0011-the-board-is-one-file.md)). It goes to
`~/.local/state/zyt/board.html` unless `--out` says otherwise, and the same file
is overwritten every time, so a reload in the browser shows the latest. The
browser it opens in is classified by your own rules like any other window: a
board opened in one you have marked as work records work time.

**Show this week's board** in the menu runs the same command, so the page is one
click away without a terminal.

## Install

Hammerspoon has to be running, with `hs.ipc` loaded for the command line.

```sh
git clone https://github.com/sapn95/zyt.git ~/git/zyt
~/git/zyt/scripts/zyt link            # symlinks the Spoon, prints the init.lua line
mkdir -p ~/.config/zyt && cp ~/git/zyt/examples/rules.json ~/.config/zyt/rules.json
```

Add `hs.loadSpoon("Zyt"):start()` to `~/.hammerspoon/init.lua`, reload
Hammerspoon, edit the rules ([docs/configuration.md](docs/configuration.md)
lists every key), then:

```sh
~/git/zyt/scripts/zyt doctor
```

Or through Homebrew, which puts `zyt` on the PATH:

```sh
brew install --HEAD sapn95/tap/zyt
zyt link                              # then add the init.lua line it prints
```

The formula is in [sapn95/homebrew-tap](https://github.com/sapn95/homebrew-tap),
beside the other tools. There is no tagged release to install: it builds `main`,
and `brew upgrade --fetch-HEAD zyt` takes the newest commit.

Window titles need Hammerspoon to have Accessibility permission; the doctor
says whether it does.

## The command

| | |
| --- | --- |
| `zyt status` | What is running, since when, and today's totals |
| `zyt work` · `zyt private` · `zyt auto` | Pin the class, or let the rules decide |
| `zyt week [2026-W38]` · `zyt day [2026-09-14]` | The record and the proposal, `--json` for a script |
| `zyt board [2026-W38\|2026-09-14]` | The same, drawn as one HTML file, and opened |
| `zyt login` | Sign in to Microsoft Graph once, for the calendar |
| `zyt meetings [--hours 24]` | The events it can see, `--json` for the Spoon |
| `zyt sync [--back 30 --ahead 60\|--all]` | Bring the record into line with the calendar |
| `zyt hook claude-code` | The stdin hook for Claude Code |
| `zyt context <source> [dir]` | Leave the same note from anything else |
| `zyt link` · `zyt unlink` | Put the Spoon where Hammerspoon finds it, take it out |
| `zyt doctor` | Check the installation |

## What is written where

`~/.config/zyt/rules.json` is yours and never in this repository
([ADR 0008](docs/adr/0008-the-rules-stay-out-of-the-repository.md)).
`~/.local/state/zyt/intervals.csv` has one row per segment,
`start,end,seconds,class,source,app`, and belongs to you too. Nothing about what
you do leaves the machine. The one thing that goes out is the calendar request,
when the `meetings` block is on: it asks Microsoft Graph for the times of your
own events and gets times back.

## Employer-neutral on purpose

The rules that make this useful are the ones that name things: the employer's
git host, the applications used at work, the words in a browser title that mean
an internal system. None of them belong in here. They live in
`~/.config/zyt/rules.json`, which is not in git and never will be
([ADR 0008](docs/adr/0008-the-rules-stay-out-of-the-repository.md)), and
`examples/rules.json` keeps the shape with invented names in it: write the rule,
not the example. The record of what you did is the same story. It stays in
`~/.local/state/zyt/`, and nothing in this repository has ever held a row of it.

Half of that is enforced. `scripts/leak-lint.sh` runs in CI and in `make lint`
and fails on any IPv4 address in the tree that is not from a documentation
range. Private space is refused too, which is the lesson from sapn95/vpnbar: it
ran the same check with private ranges allowed as a class, and two live
addresses out of a 10.x network went past it into a public history. Files nobody
has added yet are searched as well, so a new one is caught before it is
committed, and a run that could not look fails instead of reporting a clean
tree — if git will not list the files, or grep cannot read one of them, the lint
stops there. An **allowlist**, so it contains nothing worth hiding and fails
closed; the reasoning is
[container-commander's ADR 0011](https://github.com/sapn95/container-commander/blob/main/docs/adr/0011-employer-neutral-public-repo.md).

The other half cannot easily be: a git host or an application named after an
employer looks like any other word. That one is checked by reading. The one
place a key of that shape had got in was a window-title fixture in
`spec/classify_spec.lua`, and it was taken out before this repository became
public.

## Development

```sh
make check        # stylua, ruff, luacheck, shellcheck, the leak lint, busted with a coverage floor, unittest, bats
make format       # rewrites; never in CI
```

`busted`, `luacheck` and `luacov` come from luarocks, `stylua`, `shellcheck`
and `bats-core` from Homebrew, `ruff` from pipx or a venv. The Lua core is tested
without Hammerspoon ([ADR 0001](docs/adr/0001-a-pure-core-and-a-thin-shell.md));
the command line on the `python3` a Mac ships with.

## Licence

MIT.
