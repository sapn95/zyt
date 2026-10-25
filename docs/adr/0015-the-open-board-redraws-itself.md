# 0015 — The open board redraws itself every five minutes

**Status:** accepted, 2026-10-25.

## The problem

The board is a drawing of the week so far
([ADR 0011](0011-the-board-is-one-file.md)), and the week goes on after it is
drawn. A tab left open on the second monitor is a picture of the morning by the
afternoon, with no sign on it that it has stopped being true. Running
`zyt board` again is the whole fix, and it is the step that gets forgotten
exactly when the board is being watched rather than consulted.

## The decision

Five minutes, on both halves.

The page carries `<meta http-equiv="refresh" content="300">`, so the browser
re-reads the file it already has. It is markup and not a script, which keeps the
promise ADR 0011 makes: the page still runs nothing, and the reload asks the
file system for a file rather than asking a server for a week.

The Spoon rewrites that file on the same interval. `Zyt:keepBoardFresh()` starts
one `hs.timer` that runs `zyt board --no-open` and nothing else, from the first
board of the session until `Zyt:stop()`. Asking twice does nothing, so the menu
can ask when it opens a board and the command line can ask when it writes one:
`cmd_board` calls `Zyt:keepBoardFresh()` over `hs` ipc, which is how a board
opened in a terminal gets looked after too. `ZYT_FROM_SPOON=1` is set on the
command the Spoon itself runs, and the command line asks nothing when it sees
it: that process is inside Hammerspoon and waiting for this one to finish, so
the question would sit in the queue behind the answer.

Both numbers are one constant each, `BOARD_REFRESH_SECONDS`, in `scripts/zyt`
and in `Zyt.spoon/init.lua`, and each comment names the other. A reload with no
rewrite behind it shows nothing new, and a rewrite nobody reloads is invisible,
so the two halves are worth nothing apart.

The file is written to a temporary and renamed into place, the way the context
notes already are. A browser that reads it halfway through a write draws half a
week and no footer, and on a timer that is a matter of when rather than whether.

A timer that fails stops itself and says so once. Complaining every five minutes
at somebody who is not looking is worse than the stale page it is about.

Only the live board refreshes: the one in the state directory, written with
neither `--one-week` nor `--out`. Those two write a copy for somebody else, a
drawing of a week as it was, and a copy that reloads is a copy that goes blank
when the file behind it is replaced by the next week.

## What was rejected

A script in the page that fetches the week. There is nothing to fetch from
(ADR 0011), and the script is the thing the board has never had.

A shorter interval. The tracker's own tick is 30 seconds, and a board that
flickers every half minute is a board nobody can read a tooltip off. Five
minutes is short enough that the page is never wrong about the hour and long
enough to hold a mouse still in.

Rewriting the file from the tracker's tick. It is the same number of runs as a
timer of its own only if the interval matches, and tying the drawing to the
tick means a change to one interval quietly changes the other.

Watching the file in the browser instead, with a reload on change. Nothing in a
file open from `file://` is told when the file changes, and the only way to find
out is to ask again, which is what the refresh does.
