# 0014 — A private minute is not a work minute

**Status:** accepted, 2026-10-11

## The problem

The booking proposal is built from the work figure, and the work figure
counted minutes that were recorded as private.

Two sources write segments. The keyboard writes one class at a time, so the
two can never overlap there. The calendar writes a meeting as a single stretch
from its start to its end ([ADR 0013](0013-the-calendar-comes-over-graph.md)),
and the keyboard goes on recording underneath it: a private message answered
during a meeting arrives as work and as private for the same minute.

`covered()` merged each list on its own and said so in its docstring —
somebody at the keyboard in a meeting is doing both, and the day is still the
day. That is right for two work segments over one minute. It is wrong for a
work segment and a private one, because they contradict each other, and the
contradiction was resolved in favour of the one the timesheet gets.

Measured over four weeks of this machine's record, 2026-09-14 to 2026-10-11:
**68 minutes of work and private over the same minute, every one of them with
a meeting on the work side.** Fourteen of those minutes were in the week that
was about to be booked.

A second thing was true at the same time and is not the same thing. A block of
the proposal can stand over a stretch that was private, because the proposal
lays tidy blocks and does not read the day minute by minute. The booked total
was right — the week's total has always been the week's work, redistributed —
but a block saying 13:00 to 18:00 over an afternoon that held a private hour
claims that hour.

## The decision

**A minute recorded as private is not a work minute.** `summarise` takes the
private stretches out of the work stretches before it adds them up, so the
figure every other part reads has nothing private in it. The private figure is
unchanged: that time was private and is still counted as private. The day's
start and end are the first and last minute of what is left, so a day that
began with half an hour of private reading starts when the work does.

**A private stretch long enough to be a break is kept out of the blocks.** The
day's window becomes the rooms around those stretches, the day's capacity is
what those rooms hold, and the blocks are laid into them in order. A stretch
that was skipped is itself a gap, so crossing one is the break already when it
is at least `breakMinutes` long; a shorter one is topped up at the start of
the next room. Lunch is placed as before, unless a skipped stretch already
falls in the lunch window, in which case that stretch is lunch.

**Short stretches are left alone**, and `skipPrivateMinutes` (default 30) is
where the line is. This is the part that could have been got wrong by being
thorough. Private time on a workday is not an afternoon off; it is slivers.
Measured over the same four weeks: between 1 and 34 stretches a day, of which
**none on any workday reached 30 minutes** and three in all reached 15. A
proposal cut at every sliver would be twenty blocks a day and nobody can type
that into a timesheet. So the rule is: a stretch big enough to be a break is a
break, and the rest stays inside the block it falls in, paid for by the work
the booking is made of. `null` keeps every stretch out, for a record where
private time comes in hours.

## What follows

The hours drop by what was counted twice, which is minutes a week, and they
drop in the right direction. A day whose capacity shrinks hands its hours to
the other workdays the way a day over capacity always has, and what no day can
hold is the leftover, printed rather than dropped
([ADR 0006](0006-the-proposal-moves-minutes-it-never-makes-them.md)).

## What was rejected

Letting the meeting win. A calendar entry is a plan, the keyboard is a
measurement, and when they disagree about a minute the measurement is the one
that was there.

Dropping the private segment instead, so the minute is neither. It is not
neither: the person was reading something of their own, the record says so,
and the private figure is the only place that shows up.

Cutting a block at every private sliver. Measured above: unusable, and it
would make a proposal nobody can enter by hand in order to be exact about two
minutes that the week's total already accounts for.
