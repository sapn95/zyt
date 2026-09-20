# 0005 — Away starts at the last input, not when it is noticed

**Status:** accepted, 2026-09-20.

## The problem

The tracker looks every thirty seconds. A person who walks away is not noticed
until `idleSeconds` (ten minutes by default) have passed, and by then those ten
minutes have already been counted against whatever was on screen.

## The decision

When a tick finds the machine idle past the threshold, the open segment is
closed at `now - idleTime`, the moment of the last keystroke or mouse
movement, not at the tick. A lock or a sleep closes it at the event. When the
person comes back the next tick opens a fresh segment, so the idle stretch is
in no row at all.

Applications listed in `noIdleApps` are exempt: a call in Teams or Zoom is an
hour of no input that is unmistakably work. While one of them is in front, idle
time does not end the segment.

## What was rejected

A shorter threshold. Reading a long document, thinking, or a phone call at the
desk are all idle to the machine and none of them is a break. Ten minutes is
where a pause stops being a pause.

Asking on return ("were you away or working?"). It interrupts the return, and
the honest answer is usually "both, in parts", which a dialog cannot record.
