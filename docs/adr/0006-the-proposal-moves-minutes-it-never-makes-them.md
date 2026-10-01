# 0006 — The booking proposal moves minutes, it never makes or loses them

**Status:** accepted, 2026-09-20.

## The problem

What was recorded and what may be booked are two different weeks. Work happens
on a Saturday afternoon, after nine in the evening, or in a seven-hour stretch
without a break, and the timesheet on the other side has rules against each of
those: workdays only, a window of hours, a longest block, a shortest break.
Writing the recorded week into it as it was is not allowed; writing a rounded
guess is not honest.

## The decision

`zyt week` shows both. The left half is the record. The right half is a
proposal that keeps every recorded minute of work and moves only when it is
booked:

- A workday keeps its own hours, up to what the window can hold in blocks of
  `maxBlockMinutes` with `breakMinutes` between them.
- Everything else, the weekend and whatever a workday could not hold, is dealt
  out in quarter hours to the workdays with the fewest hours first, so the
  week evens out rather than piling onto Monday.
- Each day's blocks start where the real day started, rounded down to five
  minutes, and the whole day is shifted earlier when it would otherwise end
  after `latest`.
- The first break is lunch, so it is put inside the `lunch` window rather than
  wherever the first block happens to end. A day that started at nine broke at
  two in the afternoon, which is not when anybody eats, and a booking has to be
  the day somebody could have had. The morning block is still no longer than
  `maxBlockMinutes`, and a day too short to need a break, one that starts after
  the window has gone by, and one that starts early enough for a whole block to
  end before lunch could begin are laid out as before. A day holding more than
  the window can is shifted earlier as a whole, lunch with it: something has to
  give, and a block or a break of the wrong length would be a worse lie than a
  day that starts early.
- What still finds no room is printed as the leftover. It is never dropped and
  never spread thinner than the rules allow.

Days with no recorded work receive nothing unless `fillEmptyDays` says
otherwise: a day off is a day off, and hours appearing on it would be the one
thing a reader would notice.

## What was rejected

Booking the record as it was and letting the timesheet reject it. That moves
the work of redistributing to the person, at the end of the month, from memory.

Rounding the total to the nearest quarter or half hour. The record is to the
minute, the booking can be to the minute, and a rounding is a small lie in a
direction the person did not choose.
