# 0001 — A pure core and a thin Hammerspoon shell

**Status:** accepted, 2026-09-20.

## The problem

Hammerspoon cannot be imported by a test runner. Anything written against
`hs.window`, `hs.caffeinate.watcher` or `hs.menubar` can only be tried by
reloading the config and waiting for a lock, an idle period or a class change
to happen. A time tracker that is tested that way is one whose bugs show up in
a timesheet.

## The decision

Everything that decides anything lives in `Zyt.spoon/zyt/` and imports nothing
from Hammerspoon: the rules and their checks, the classifier, the repository
lookup, the segment state machine and the day totals. `init.lua` is the only
file that talks to Hammerspoon, and it holds no decisions worth testing: it
reads the screen, hands the observation over, and writes what comes back.

The coverage floor in `scripts/coverage-floor.lua` counts the core only.
`init.lua` is not covered; it is kept short enough to read instead.

## What was rejected

Mocking `hs` with a fake table. The fake would be more permissive than the real
thing in exactly the places that matter (what `focusedWindow()` returns when a
menu is open, what `idleTime()` does across a wake), and a test that passes
against a fake more forgiving than the thing it doubles is worth less than no
test.

## The cost

Two places to look when following one tick through, and a small interface
(`clock.iso`, `resolve`, the observation table) kept honest by hand.
