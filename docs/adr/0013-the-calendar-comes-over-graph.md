# 0013 — The calendar comes over Graph, not out of Outlook

**Status:** accepted, 2026-09-30

## The problem

A meeting in a room is work, and zyt records none of it. It watches the window
in front, and there is no window: the notebook is shut, or it sits open and
untouched until the idle rule closes the segment at the last keystroke
([ADR 0005](0005-away-starts-at-the-last-input.md)). The hour comes back in
`zyt week` as an hour that was never worked, and the person has to remember it
and add it by hand, which is the thing this tracker exists not to make them do.

The calendar knows. It says a meeting was on, when it started, when it ended
and whether they said they would be there.

## The decision

The events come from Microsoft Graph, `/me/calendarView`, with a token the
tracker holds itself.

**Why not Outlook.** Outlook for Mac has an AppleScript dictionary with
`calendar event` in it, and reading the calendar of the application on the
machine would need no token, no network and no app registration. It does not
work any more. Measured on this machine on 2026-09-30: the dictionary lists 29
calendars, the reader's own returns 63 events whose newest is five weeks old,
`every exchange account` answers 0, `default account` is `missing value`, and
`message 1 of inbox` is an invalid index. Delegate calendars from an account
that was replaced still hold four thousand events each, so the interface works
and the data is simply not in it: the current mailbox is not in the store
AppleScript reads. The same goes for the local files, which are a React cache
and nothing else, and for the macOS calendar, which has no account.

**Why `calendarView` and not `events`.** A weekly meeting is one event with a
recurrence rule, and the occurrence that fell on Tuesday is not in it.
`calendarView` takes a window and hands back the occurrences inside it, which is
the question being asked.

**What is asked for.** `start`, `end`, `isAllDay`, `showAs`, `responseStatus`
and `isCancelled`. No subject, no attendees, no body, no location: the tracker
needs to know that there was a meeting and when, and a subject line would be the
one thing it stored that somebody could be sorry about. The `$select` is the
enforcement, and a test pins it.

**How it signs in.** The app registration is the one the Graph MCP server
already uses, a single-tenant public client with the reader assigned and the
delegated scopes consented for that person alone
(`KD_TERRAFORM/terraform-azure-graph-reader-app`). `zyt login` runs the
authorization-code flow with PKCE against `http://localhost:3000`, so the code
comes back to a server on this machine and never leaves it. What is kept is the
refresh token, in the login keychain. Access tokens last an hour and are asked
for again on every run rather than stored.

The token goes to `security` on its command line, where another process on this
machine could read it for as long as that call takes. The alternative was a file
in the state directory, readable for as long as it exists. Neither is perfect
and the shorter window won.

## A meeting is an hour whether or not anybody typed

A row is written for every meeting the calendar has, the whole of it, and not
only for the part of it the tracker recorded nothing in. Somebody can be at the
keyboard in a meeting: both are true, the record says both, and a record that
had to choose would be wrong about one of them. The first version wrote only
what was left of a meeting after the recorded hours were taken out, and a
meeting that began at four showed up as beginning at twenty past, which is not
when it began.

What stops the hour from being counted twice is the arithmetic. The totals take
the union of the hours of a class rather than their sum: two rows over one hour
are one hour, and the day is still the day. A gap between two covered stretches
is still the break it was.

What counts is a meeting that was not cancelled, is not an all-day marker, does
not say `free`, and was not declined: a meeting turned down is somebody else's
hour. The busy statuses that count are a rule, so `tentative` can be left out by
whoever does not want it. Overlapping and touching meetings are merged, because
the record holds time and not meetings, and what is left shorter than
`minimumSeconds` is dropped.

Nothing is written for time that has not happened, and nothing is written into
the segment that is open: the minutes being recorded right now are being
recorded properly, and a meeting still going on would otherwise get a row that
ends at this moment and another one at the next round.

## Taking a row back out

A meeting that moved, was shortened or called off leaves a row behind that is no
longer true, and nothing in a record that only ever grows can say so. Every
`syncHours` the Spoon goes over a window, `lookbackDays` back and
`lookaheadDays` forward, and makes the meeting rows in it say what the calendar
says: what is missing is written, what the calendar no longer accounts for is
taken out.

Only rows whose source is `meeting` are ever removed, and only when they lie
whole inside the window: a row reaching past its edge is about time this round
knows nothing about. Rows the tracker wrote itself are never touched, whether or
not a meeting covers the same hour. The two say different things about it, and
the arithmetic is where they meet.

The file is written whole and renamed into place, so a reader sees either the
old one or the new one. The Spoon is single-threaded and does this between
ticks, which is what keeps a row written in the same moment from being lost.

## What was rejected

Publishing the calendar as an ICS URL and fetching it. It is a secret URL that
reads the whole calendar to anybody who has it, it depends on a tenant setting
that can be turned off under you, and subjects come with it whether they are
wanted or not.

Adding the mailbox to the macOS calendar and reading that. It works and it needs
no token at all, but it is a second sync of the whole mailbox, set up by hand on
every machine, and it drags the calendar into an application nobody uses here.

A subject-based rule, so that some meetings count as private. The class comes
from the calendar the meeting is in, and a rule that reads subjects would need
the subjects. If a private calendar is ever added, it gets its own class.
