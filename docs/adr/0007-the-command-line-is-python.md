# 0007 — The command line is Python, the Spoon is Lua

**Status:** accepted, 2026-09-20.

## The problem

The Spoon has to be Lua; that is what Hammerspoon runs. The report is
arithmetic over a CSV: split segments at midnight, sum per day, lay blocks into
a window. Two languages in one small repository need a reason.

## The decision

`scripts/zyt` is Python, standard library only, and nothing newer than the
`python3` a Mac ships with (3.9 at the time of writing). It reads the rows
directly, so the report works with Hammerspoon stopped, on a copy of the file,
or on another machine. It also carries the hook, which has to run in
milliseconds from inside another tool, and the doctor.

The Spoon does one piece of reading back, today's totals for the menu, and
that is kept in Lua on purpose: the menu must not shell out on every open.

## What was rejected

A Lua command line run through `hs`. It depends on Hammerspoon being up and on
its ipc answering, which is precisely what the doctor is there to find out; a
report that cannot be produced while the tracker is broken is not much of a
report.

A Bash command line, which is what `vpnbar` has. It fits there because that
tool's command line only links, unlinks and diagnoses. Date arithmetic in Bash
is a bug factory.

Doing the report in Lua inside the Spoon and having the command line ask for
it. See the first rejection, plus a menu item that blocks on a full week's
computation.
