# 0002 — An unknown window is sticky, not a third class

**Status:** accepted, 2026-09-20.

## The problem

Most windows say nothing about whose time they are on. Finder, a file dialog,
a password manager, a browser tab whose title is a person's name: none of them
is work or private on its own. A tracker that classifies per window has to
decide what to do with them, and there are a lot of them.

## The decision

A window the rules have no opinion on inherits the class that was running when
it came to the front. The tracker keeps the last class it knew and carries on
with it; the row says `sticky` as its source so the report can tell a decision
from an inheritance. When nothing has ever been decided, `defaultClass` from
the rules file applies.

The manual switch in the menu exists for when that inheritance is wrong. It
pins the class until the next lock, because a lock is the natural end of a
stretch of work, and a pin that outlived it would quietly misfile the next
morning.

## What was rejected

A third class, `unknown`, to be sorted later. It moves the classification from
the moment it happens, when the person knows what they were doing, to a review
at the end of the week, when they do not. Nobody does that review, and the
unknown pile becomes the biggest one.

Classifying by the majority of the last few minutes. It smooths over a real
context switch as readily as over a Finder window, and it makes the boundary
between two segments a matter of interpretation.
