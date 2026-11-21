# 0016 — Time away is not work, and a day away is a day off

**Status:** accepted, 2026-11-21.

## The problem

Three things in the calendar were booked as work when they were not.

An invitation nobody answered counted like an accepted one, because only a
`declined` answer kept a meeting out. A five-hour invitation left unanswered
became five hours of work.

A meeting inside an out-of-office block counted too. A recurring fifteen-minute
call on a morning blocked for an appointment is in the diary, but nobody was in
it.

And a day away had no meaning for the proposal. An all-day out-of-office entry
is no hour, so it was dropped, and the day looked like a workday with very few
hours. `propose` deals the weekend and the overflow to the days with the fewest
hours first ([ADR 0006](0006-the-proposal-moves-minutes-it-never-makes-them.md)),
so a day away with a glance at the mail on it was the first to be filled.

All three were found in November 2026, when a month booked from the proposal
had to be corrected by hand: 3.7 hours came only from such events, and three days
away had been given a full day of work.

## The decision

`notResponded` is treated like `declined`: the meeting does not count. A
`tentativelyAccepted` answer still counts, because somebody said they might come.

`oof` is no longer in the default `statuses`. A timed out-of-office event that
was not cancelled or declined is a stretch of time away, and `meetings.wanted`
cuts those stretches out of the meetings before it merges them. A rules file that
lists `oof` says that away blocks are work, and then nothing is cut, so the old
behaviour is one setting away.

An all-day out-of-office entry marks each day it covers as a day off.
`meetings.daysOff` reads the dates at noon, so an all-day event that comes back
as UTC midnight and one that comes back as local midnight give the same date.
`Zyt:syncMeetings` keeps the list in `days-off.json`: inside the synced window it
is whatever the calendar says now, and outside it the days are kept, the same
rule the meeting rows follow. `report.daysOff` adds days by hand.

`propose` takes the days off as an argument. A day off keeps the work recorded on
it up to its capacity and is never eligible for the pool. The minutes it would
have received go to the other workdays, and what finds no room is still the
leftover. No minute is invented or dropped, which is the promise of ADR 0006.

## What it costs

A meeting you attended while marked out of office is lost unless `oof` is in
`statuses`. A day off is read from your own calendar only: an absence that is
not in it needs `report.daysOff`.

The days off live in a second file next to the record. The record stays a list
of hours, and the Spoon remains the only writer of both.
