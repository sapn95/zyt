# Configuration

`~/.config/zyt/rules.json` (or `$XDG_CONFIG_HOME/zyt/rules.json`). Every key is
optional; `examples/rules.json` shows them all. The Spoon reads the file at
start and on **Reload the rules**; the command line reads `report` on every
run.

| Key | Default | What |
| --- | --- | --- |
| `defaultClass` | `"work"` | The class before anything has been decided ([ADR 0002](adr/0002-unknown-is-sticky-not-a-third-class.md)) |
| `labels` | `{"work":"W","private":"P","away":"·"}` | What the menu-bar item shows; a pinned class is shown in brackets |
| `tickSeconds` | `30` | How often the screen is looked at; a switch to another application is looked at at once. Applied on **Reload the rules** |
| `idleSeconds` | `600` | No input for this long ends the segment, backdated to the last input ([ADR 0005](adr/0005-away-starts-at-the-last-input.md)) |
| `signalSeconds` | `300` | How long a coding tool's note counts: as presence, and as the class once nobody types ([ADR 0004](adr/0004-a-tool-says-where-it-is-working.md)) |
| `chatSeconds` | `14400` | How long a chat counts as open after the last prompt typed into it ([ADR 0010](adr/0010-which-chat-of-several.md)) |
| `noIdleApps` | `[]` | Applications in front of which idle time does not count: calls |
| `repoRoots` | `["~/git"]` | Where a word from a window title is looked up as a directory |
| `remotes` | `[]` | `{"match": "<substring of the remote URL>", "class": "work"\|"private"}`, first match wins |
| `apps` | `{}` | Application name to `"work"`, `"private"` or `"repo"` |
| `titles` | `[]` | `{"contains": "<text>", "class": …}`, case-insensitive, first match wins |
| `prompt` | `{"enabled": true, "seconds": 20, "cooldownSeconds": 1800}` | The panel that asks when nothing else knows: whether, how long it stays, how long before an unanswered question is asked again ([ADR 0009](adr/0009-ask-once-and-remember.md)) |
| `report` | see below | The booking rules |

## How a moment is classified

1. A manual pin from the menu or `zyt work` / `zyt private`, until the next lock.
2. With no input for `idleSeconds` and a fresh note from a coding tool: the
   class of that tool's repository.
3. `apps[<frontmost application>]` when it is `work` or `private`.
4. For an application marked `repo`: the remote of the repository it is in,
   found from its working directory, from an absolute path in its title, from
   a word in its title that names a checkout, from the chats open in it, or
   from a recent tool note written from inside that same application, in that
   order ([ADR 0003](adr/0003-a-terminal-belongs-to-its-remote.md)). Chats that
   disagree are a question, not a guess
   ([ADR 0010](adr/0010-which-chat-of-several.md)).
5. The first `titles` rule whose text is in the window title.
6. An answer given earlier for this repository or application.
7. Otherwise the class that was already running, and a question if none has
   been asked about this repository or application lately.

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
| `~/.local/state/zyt/context.json` | The last note a coding tool left: what some session is working on |
| `~/.local/state/zyt/chat.json` | The last prompt the person typed: the chat they are talking to |
| `~/.local/state/zyt/sessions/<id>.json` | One per chat session: when it was last worked in and last typed into, and the repository it last touched ([ADR 0010](adr/0010-which-chat-of-several.md)) |
| `~/.local/state/zyt/sessions/.lock` | Empty, and held while the notes are merged and the expired ones dropped, so two hooks cannot undo each other |
| `~/.local/state/zyt/learned.json` | The answers given to the panel, `"remote:<url>"` or `"app:<name>"` to `work`, `private` or `inherit` |

`$XDG_STATE_HOME` moves the state directory. Timestamps are local time with
the offset written out, so a week spanning a clock change still adds up.

## The application names

`apps` is keyed by the name macOS gives the application, which is not always
the name on the icon: Visual Studio Code is `Code`. The tooltip on the menu-bar
item shows the name of whatever is in front right now, so hover before you
write a rule.
