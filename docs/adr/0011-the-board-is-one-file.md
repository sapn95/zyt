# 0011 — The board is one file, with no script in it and nothing to fetch

**Status:** accepted, 2026-09-21; extended 2026-09-23 with the weeks either
side, and 2026-10-01 with a lane for the meetings.

## The problem

`zyt week` prints a table, and a table is the wrong shape for two of the
questions the week raises: where the holes in a day were, and how far the
proposal has moved from what actually happened. Both are questions about
position in time. A column of totals has no position in it, and reading
`08:00-13:00, 13:30-17:40` against `start 08:02  end 16:42` is arithmetic done
by eye.

## The decision

`zyt board` writes one HTML file and opens it. Each day gets three lanes on a
shared hour scale: the hours at the keyboard above, the hours the calendar
accounted for under them, and what is proposed for booking below both.

The meetings have a lane of their own because they are a different kind of
fact. The tracker saw the hours above; the hours in the middle are what a
calendar said about a room somebody was in, and a day where the two disagree
is worth seeing rather than adding up. They are both work and the totals say
so, which is the other reason to separate them: the figure on the right has to
keep meaning all of it.

The figures above the week say it in the same order a person asks it, decided
25.10.2026: what was recorded at all, how much of it came out of the calendar,
the work against what would be booked, the private time, and what the rules
could not place. The calendar figure is inside the work one, with the same
private minutes taken out of both, so it can be held against the work total
without being added to it; a figure of a part that can exceed the whole it is in
is a figure nobody can read.
Holding one against the other is then looking, not counting. The scale is the
window that may be booked, widened to whole hours around anything recorded or
proposed outside it, so a Sunday evening is drawn where it happened instead of
being clipped off the end of the day.

The file has a `<style>` element in its head and nothing else in it: no script,
no font, no image, no stylesheet to go and get. Every bar is a percentage in a
`style=` attribute and every exact time is a `title=`, which the browser turns
into a tooltip for free. Dark mode is one `prefers-color-scheme` query. The two
classes keep the blue and the purple of the menu-bar panel, so the board and the
Spoon say the same colour about the same thing.

Going back a week is a link into the same file. Every week from the first one
with hours in it to the last is written out, together with the week that was
asked for when it lies outside them, one `<section>` each, and the address says
which is on show: the week whose id it ends in through `:target`, and the week
that was asked for while it ends in nothing. Paging has to stay inside the file,
because a page that fetched the next week would need something to fetch it from.
Where `:has()` is not understood the weeks stand one under the other and the
links still jump to the right one. A quiet week costs about nine kilobytes of the
file and a full one about twenty, so a year of it is roughly a megabyte, which a
browser opens without thinking about it.

`--one-week` writes the week on its own. The board is as private as
`intervals.csv` it is drawn from, and a file that holds every week recorded is a
lot to hand over when the question was about one of them.

A run of segments of one class with no real gap between them is drawn as one
bar. `intervals.csv` can hold a dozen of them seconds long each, from a minute
where the class flickered because the window did. The totals are the same either
way, and one bar per run is the difference between a lane that can be read and a
smear.

## What was rejected

A charting library. It would arrive either as a bundle in the repository or as a
tag in the page. The tag sends the week to somebody else's server every time the
file is opened, which is the one thing the rest of zyt is careful never to do
([ADR 0008](0008-the-rules-stay-out-of-the-repository.md) is the same instinct
about the rules). The bundle is more code to keep than the drawing it would do.

Serving it on a local port. A file has no lifecycle: nothing to start, nothing
to leave running, nothing to notice six weeks later. The browser already knows
how to open a file.

An image. A PNG cannot be hovered for the exact times, cannot be searched for a
date, and would need a renderer installed to make it at all.

A file per week, linked to its neighbours. The arrow forward would have to point
at a week nobody has written yet, so it would either go nowhere or make the
command write out a run of files, and the directory would fill up with weeks
again.

Leaving the board in a temporary directory. The default is
`~/.local/state/zyt/board.html`, one file that is overwritten, so a reload in
the browser shows this run rather than a directory slowly filling with weeks.
`--out` puts it anywhere else.
