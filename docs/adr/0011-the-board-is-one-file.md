# 0011 — The board is one file, with no script in it and nothing to fetch

**Status:** accepted, 2026-09-21.

## The problem

`zyt week` prints a table, and a table is the wrong shape for two of the
questions the week raises: where the holes in a day were, and how far the
proposal has moved from what actually happened. Both are questions about
position in time. A column of totals has no position in it, and reading
`08:00-13:00, 13:30-17:40` against `start 08:02  end 16:42` is arithmetic done
by eye.

## The decision

`zyt board` writes one HTML file and opens it. Each day gets two lanes on a
shared hour scale: what was recorded above, what is proposed for booking below.
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

Leaving the board in a temporary directory. The default is
`~/.local/state/zyt/board.html`, one file that is overwritten, so a reload in
the browser shows this run rather than a directory slowly filling with weeks.
`--out` puts it anywhere else.
