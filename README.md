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

5. **Otherwise it asks, once.** A small panel under the menu bar: Work,
   Private, or Don't ask. The answer is kept for that repository or that
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
whichever panel you are reading. When they straddle both, zyt asks which chat
you are in and puts the repositories on the buttons: nothing on screen can say,
because the editor does not expose its panels. The same list is in the menu
([ADR 0010](docs/adr/0010-which-chat-of-several.md)).

A terminal is the exception, because it knows. It gives every shell it opens an
id for the pane it opened it in, the hook writes that id into the note, and it
answers which pane is in front when it is asked. Four chats in four tabs are then
told apart by the terminal itself: switching tabs between an employer repository
and a private one changes the class and asks nothing
([ADR 0012](docs/adr/0012-the-pane-in-front-is-the-chat.md)).

```json
"hooks": {
  "UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "zyt hook claude-code" }] }],
  "PostToolUse":      [{ "hooks": [{ "type": "command", "command": "zyt hook claude-code" }] }]
}
```

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
block longer than `maxBlockMinutes`, `breakMinutes` between blocks. Weekend
hours and anything a workday could not hold are dealt out to the workdays with
the fewest hours first; a day keeps its real start where it fits. What finds
no room is printed as the leftover rather than dropped
([ADR 0006](docs/adr/0006-the-proposal-moves-minutes-it-never-makes-them.md)).
`zyt day` is one day of the same; `--json` on either gives it to a script.

## The board

```sh
zyt board                                      # this week, written and opened
zyt board 2026-W38                             # another week
zyt board 2026-09-14                           # one day on its own
zyt board --out ~/Desktop/week.html --no-open
```

The same week, drawn instead of tabulated. Each day gets two lanes on one hour
scale: above it what was recorded, work in blue and private in purple, below it
the blocks the proposal would have you book. Hover a bar and it names its exact
times. The scale covers the hours that may be booked and widens for anything
outside them, so a Sunday evening shows up where it happened.

```text
            07   08   09   10   11   12   13   14   15   16   17   18
Mon 14.09.       ████████████████████▓▓▓▓ ███████████████████     7h50 · 0h45 private
                 ▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒▒  ▒▒▒▒▒▒▒▒▒▒▒▒▒▒       08:00–13:00 · 13:30–16:20
```

One file with a `<style>` in it and nothing else: no script, no font, no
stylesheet, nothing fetched when it opens, and dark mode follows the system
([ADR 0011](docs/adr/0011-the-board-is-one-file.md)). It goes to
`~/.local/state/zyt/board.html` unless `--out` says otherwise, and the same file
is overwritten every time, so a reload in the browser shows the latest. The
browser it opens in is classified by your own rules like any other window: a
board opened in one you have marked as work records work time.

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
`brew tap sapn95/zyt https://github.com/sapn95/zyt.git && brew install --HEAD sapn95/zyt/zyt`,
then `zyt link` as above. While the repository is private the tap URL and the
formula's `head` are the SSH form, `ssh://git@github.com/sapn95/zyt.git`, and
the install needs a GitHub SSH key.

Window titles need Hammerspoon to have Accessibility permission; the doctor
says whether it does.

## The command

| | |
| --- | --- |
| `zyt status` | What is running, since when, and today's totals |
| `zyt work` · `zyt private` · `zyt auto` | Pin the class, or let the rules decide |
| `zyt week [2026-W38]` · `zyt day [2026-09-14]` | The record and the proposal, `--json` for a script |
| `zyt board [2026-W38\|2026-09-14]` | The same, drawn as one HTML file, and opened |
| `zyt hook claude-code` | The stdin hook for Claude Code |
| `zyt context <source> [dir]` | Leave the same note from anything else |
| `zyt link` · `zyt unlink` | Put the Spoon where Hammerspoon finds it, take it out |
| `zyt doctor` | Check the installation |

## What is written where

`~/.config/zyt/rules.json` is yours and never in this repository
([ADR 0008](docs/adr/0008-the-rules-stay-out-of-the-repository.md)).
`~/.local/state/zyt/intervals.csv` has one row per segment,
`start,end,seconds,class,source,app`, and belongs to you too. Nothing leaves
the machine.

## Development

```sh
make check        # stylua, ruff, luacheck, shellcheck, the leak lint, busted with a coverage floor, unittest
make format       # rewrites; never in CI
```

`busted`, `luacheck` and `luacov` come from luarocks, `stylua` and
`shellcheck` from Homebrew, `ruff` from pipx or a venv. The Lua core is tested
without Hammerspoon ([ADR 0001](docs/adr/0001-a-pure-core-and-a-thin-shell.md));
the command line on the `python3` a Mac ships with.

## Licence

MIT.
