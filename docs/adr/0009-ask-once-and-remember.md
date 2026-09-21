# 0009 — Ask once, and remember the answer

**Status:** accepted, 2026-09-20.

## The problem

Rules for every application, every git host and every title word are a lot
of rules, and they are wrong at the edges: the repository that exists for the
job but lives on GitHub, the editor that is used for both, the tool nobody
thought of. Each edge costs a round trip to a JSON file, and until it is made,
the class is whatever happened to be running before.

## The decision

When no rule and no earlier answer knows a window, the Spoon asks. A small
panel appears under the menu bar naming the repository (or, without one, the
application) with three buttons: Work, Private, Don't ask. The answer is
written to `learned.json` in the state directory under `remote:<url>` or
`app:<name>` and is used from then on; Don't ask records `inherit`, which
keeps [ADR 0002](0002-unknown-is-sticky-not-a-third-class.md)'s behaviour for
windows that genuinely have no side, such as Finder.

The panel does not block anything: it goes away by itself after
`prompt.seconds`, an unanswered question is not repeated for
`prompt.cooldownSeconds`, and the class stays what it was until there is an
answer. It is only shown while the person is at the keyboard (idle under two
minutes) and the screen is unlocked; a lock takes it down.

The rules file keeps the answers that should be versioned and explained; the
learned file holds the rest. Moving an answer from one to the other is a copy.

**Forgetting has two scopes.** An answer that turns out wrong is nearly always
the one about the window in front, and having to drop every answer ever given to
fix it costs a day of being asked about Finder and the login window again. So the
menu offers both, and the narrow one names what it will forget — the repository
or the application the menu-bar item is about at that moment. It takes the chat
named for that application with it
([ADR 0010](0010-which-chat-of-several.md)): both are answers about the same
window, and forgetting one while keeping the other leaves the window classified
by whichever was kept, which is the confusing half of a fix.

## What was rejected

Asking with a modal dialog. It stops the timer and the watchers while it
waits, and it interrupts whatever the person was doing for a question the
tracker can afford to have answered a minute later.

Writing the answer straight into the rules file. That file is versioned and
symlinked from a repository on this machine, and a tracker that edits a
versioned file every time it learns something is a tracker that produces
uncommitted changes all day.
