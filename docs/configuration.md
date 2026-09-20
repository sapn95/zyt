# Configuration

`~/.config/zyt/rules.json` (or `$XDG_CONFIG_HOME/zyt/rules.json`). Every key is
optional; `examples/rules.json` shows them all. The Spoon reads the file at
start and on **Reload the rules**; the command line reads `report` on every
run.

| Key | Default | What |
| --- | --- | --- |
| `defaultClass` | `"work"` | The class before anything has been decided ([ADR 0002](adr/0002-unknown-is-sticky-not-a-third-class.md)) |
| `labels` | `{"work":"W","private":"P","away":"·"}` | What the menu-bar item shows; a pinned class is shown in brackets |
| `tickSeconds` | `30` | How often the screen is looked at; a switch to another application is looked at at once |
| `idleSeconds` | `600` | No input for this long ends the segment, backdated to the last input ([ADR 0005](adr/0005-away-starts-at-the-last-input.md)) |
| `signalSeconds` | `300` | How long a coding tool's note counts ([ADR 0004](adr/0004-a-tool-says-where-it-is-working.md)) |
| `noIdleApps` | `[]` | Applications in front of which idle time does not count: calls |
| `repoRoots` | `["~/git"]` | Where a word from a window title is looked up as a directory |
| `remotes` | `[]` | `{"match": "<substring of the remote URL>", "class": "work"\|"private"}`, first match wins |
| `apps` | `{}` | Application name to `"work"`, `"private"` or `"repo"` |
| `titles` | `[]` | `{"contains": "<text>", "class": …}`, case-insensitive, first match wins |
| `report` | see below | The booking rules |

## How a moment is classified

1. A manual pin from the menu or `zyt work` / `zyt private`, until the next lock.
2. `apps[<frontmost application>]` when it is `work` or `private`.
3. For an application marked `repo`: the remote of the repository it is in,
   found from its working directory, from a word in its title, or from a
   recent tool note, in that order ([ADR 0003](adr/0003-a-terminal-belongs-to-its-remote.md)).
4. The first `titles` rule whose text is in the window title.
5. Otherwise the class that was already running.

## `report`

| Key | Default | What |
| --- | --- | --- |
| `workdays` | `[1,2,3,4,5]` | ISO weekdays that may be booked (1 is Monday) |
| `earliest` | `"07:00"` | No block starts before this |
| `latest` | `"20:00"` | No block ends after this |
| `maxBlockMinutes` | `300` | The longest block |
| `breakMinutes` | `30` | The break between two blocks |
| `defaultStart` | `"08:00"` | Where a day with no recorded start begins |
| `fillEmptyDays` | `false` | Whether a workday with no recorded work may receive moved hours |

How these turn a recorded week into a proposal is in
[ADR 0006](adr/0006-the-proposal-moves-minutes-it-never-makes-them.md).

## Where things are

| | |
| --- | --- |
| `~/.config/zyt/rules.json` | The rules |
| `~/.local/state/zyt/intervals.csv` | One row per segment: `start,end,seconds,class,source,app` |
| `~/.local/state/zyt/open.json` | The segment running now, rewritten every tick so a crash loses at most one tick |
| `~/.local/state/zyt/context.json` | The last note a coding tool left |

`$XDG_STATE_HOME` moves the state directory. Timestamps are local time with
the offset written out, so a week spanning a clock change still adds up.

## The application names

`apps` is keyed by the name macOS gives the application, which is not always
the name on the icon: Visual Studio Code is `Code`. The tooltip on the menu-bar
item shows the name of whatever is in front right now, so hover before you
write a rule.
