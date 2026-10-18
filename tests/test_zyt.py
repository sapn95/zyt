"""The report's arithmetic, and the note the hook leaves behind."""

import argparse
import contextlib
import datetime as dt
import importlib.machinery
import importlib.util
import io
import json
import os
import socket
import sys
import tempfile
import threading
import time
import unittest
import urllib.parse
import urllib.request
from pathlib import Path
from unittest import mock

# The command has no .py extension, so it is loaded by path. It has to be in
# sys.modules before it runs: dataclasses looks its module up there.
SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "zyt"
SPEC = importlib.util.spec_from_loader("zyt", importlib.machinery.SourceFileLoader("zyt", str(SCRIPT)))
zyt = importlib.util.module_from_spec(SPEC)
sys.modules["zyt"] = zyt
SPEC.loader.exec_module(zyt)

TZ = dt.timezone(dt.timedelta(hours=2))
REPORT = dict(zyt.REPORT_DEFAULTS)


def at(day: str, clock: str) -> dt.datetime:
    return dt.datetime.fromisoformat(f"{day}T{clock}:00+02:00")


def private_from(first: int, last: int) -> dict:
    """One stretch of a day's `privateAt`, from whole minutes of its day."""
    return {"from": first, "to": last, "first": first * 60, "last": last * 60}


def seg(day: str, start: str, end: str, cls: str = "work") -> zyt.Segment:
    end_day = day
    if end < start:  # over midnight
        end_day = (dt.date.fromisoformat(day) + dt.timedelta(days=1)).isoformat()
    return zyt.Segment(at(day, start), at(end_day, end), cls)


class SplitAndSummarise(unittest.TestCase):
    def test_a_segment_over_midnight_is_cut_at_midnight(self):
        parts = zyt.split_by_day([seg("2026-09-19", "23:30", "00:30")])
        self.assertEqual(
            [(p.start.isoformat(), p.end.isoformat()) for p in parts],
            [
                ("2026-09-19T23:30:00+02:00", "2026-09-20T00:00:00+02:00"),
                ("2026-09-20T00:00:00+02:00", "2026-09-20T00:30:00+02:00"),
            ],
        )

    def test_summary_has_first_start_last_end_and_the_longest_gap(self):
        summary = zyt.summarise(
            [
                seg("2026-09-14", "08:02", "12:00"),
                seg("2026-09-14", "12:00", "12:45", "private"),
                seg("2026-09-14", "13:00", "16:57"),
                seg("2026-09-14", "17:10", "17:20"),
            ]
        )
        self.assertEqual(summary["start"], at("2026-09-14", "08:02"))
        self.assertEqual(summary["end"], at("2026-09-14", "17:20"))
        self.assertEqual(summary["work"], (238 + 237 + 10) * 60)
        self.assertEqual(summary["private"], 45 * 60)
        self.assertEqual(summary["break"], 60 * 60)

    def test_an_empty_day(self):
        self.assertEqual(
            zyt.summarise([]),
            {"start": None, "end": None, "work": 0, "private": 0, "privateAt": [], "break": 0},
        )


class Union(unittest.TestCase):
    def test_an_hour_covered_twice_is_one_hour(self):
        day = [
            seg("2026-09-14", "09:00", "10:00"),
            seg("2026-09-14", "09:00", "10:00"),
            seg("2026-09-14", "09:30", "11:00"),
        ]
        # somebody at the keyboard in a meeting is doing both, and both are
        # written: two hours of the day have passed, not three and a half
        summary = zyt.summarise(day)
        self.assertEqual(summary["work"], 7200)
        self.assertEqual(summary["end"].hour, 11)

    def test_a_gap_between_two_covered_stretches_is_still_a_break(self):
        day = [
            seg("2026-09-14", "09:00", "10:00"),
            seg("2026-09-14", "09:30", "10:30"),
            seg("2026-09-14", "12:00", "13:00"),
        ]
        summary = zyt.summarise(day)
        self.assertEqual(summary["work"], 5400 + 3600)
        # the break is from the end of what was covered, not from the end of
        # whichever row happened to be sorted last
        self.assertEqual(summary["break"], 5400)


class PrivateIsNotWork(unittest.TestCase):
    def test_a_private_minute_inside_a_meeting_is_not_a_work_minute(self):
        # The calendar writes the meeting as one stretch and the keyboard goes
        # on recording underneath it, so both arrive for the same minute.
        day = [
            zyt.Segment(at("2026-09-14", "09:00"), at("2026-09-14", "11:00"), "work", zyt.MEETING),
            seg("2026-09-14", "09:40", "10:10", "private"),
        ]
        summary = zyt.summarise(day)
        self.assertEqual(summary["work"], 90 * 60)
        self.assertEqual(summary["private"], 30 * 60)
        self.assertEqual(
            summary["privateAt"],
            [{"from": 9 * 60 + 40, "to": 10 * 60 + 10, "first": 34800, "last": 36600}],
        )

    def test_the_day_starts_and_ends_at_work(self):
        day = [
            seg("2026-09-14", "08:00", "09:00", "private"),
            seg("2026-09-14", "08:30", "12:00"),
            seg("2026-09-14", "12:00", "12:30", "private"),
        ]
        summary = zyt.summarise(day)
        self.assertEqual(summary["start"], at("2026-09-14", "09:00"))
        self.assertEqual(summary["end"], at("2026-09-14", "12:00"))
        self.assertEqual(summary["work"], 3 * 60 * 60)

    def test_a_day_that_was_only_private_has_no_work_in_it(self):
        summary = zyt.summarise([seg("2026-09-14", "20:00", "22:00", "private")])
        self.assertEqual(summary["work"], 0)
        self.assertIsNone(summary["start"])

    def test_seconds_of_a_stretch_are_kept_out_at_both_ends(self):
        day = [
            zyt.Segment(at("2026-09-14", "09:00"), at("2026-09-14", "11:00"), "work", zyt.MEETING),
            zyt.Segment(
                dt.datetime.fromisoformat("2026-09-14T09:40:30+02:00"),
                dt.datetime.fromisoformat("2026-09-14T09:41:20+02:00"),
                "private",
            ),
        ]
        # 09:40:30 to 09:41:20 is the minutes 09:40 and 09:41, both of them,
        # and it lasted the fifty seconds it lasted
        self.assertEqual(
            zyt.summarise(day)["privateAt"],
            [{"from": 9 * 60 + 40, "to": 9 * 60 + 42, "first": 34830, "last": 34880}],
        )

    def test_a_stretch_that_runs_to_midnight_ends_at_the_end_of_the_day(self):
        day = [seg("2026-09-14", "23:00", "00:00", "private")]
        # 00:00 belongs to the day after and is not before 23:00
        self.assertEqual(
            zyt.summarise(day)["privateAt"],
            [{"from": 23 * 60, "to": 24 * 60, "first": 82800, "last": 86400}],
        )

    def test_without_puts_the_holes_in_order_itself(self):
        whole = [[at("2026-09-14", "08:00"), at("2026-09-14", "13:00")]]
        holes = [
            [at("2026-09-14", "11:00"), at("2026-09-14", "12:00")],
            [at("2026-09-14", "09:00"), at("2026-09-14", "09:30")],
        ]
        self.assertEqual(
            zyt.without(whole, holes),
            [
                [at("2026-09-14", "08:00"), at("2026-09-14", "09:00")],
                [at("2026-09-14", "09:30"), at("2026-09-14", "11:00")],
                [at("2026-09-14", "12:00"), at("2026-09-14", "13:00")],
            ],
        )

    def test_without_takes_the_holes_out_of_the_stretches(self):
        whole = [[at("2026-09-14", "08:00"), at("2026-09-14", "12:00")]]
        holes = [[at("2026-09-14", "09:00"), at("2026-09-14", "09:30")]]
        self.assertEqual(
            zyt.without(whole, holes),
            [
                [at("2026-09-14", "08:00"), at("2026-09-14", "09:00")],
                [at("2026-09-14", "09:30"), at("2026-09-14", "12:00")],
            ],
        )
        # a hole over the whole stretch leaves nothing, and one outside it
        # leaves the stretch alone
        self.assertEqual(zyt.without(whole, [[at("2026-09-14", "07:00"), at("2026-09-14", "13:00")]]), [])
        self.assertEqual(zyt.without(whole, [[at("2026-09-14", "13:00"), at("2026-09-14", "14:00")]]), whole)


class KeptOut(unittest.TestCase):
    def summary(self, *spans):
        return {"privateAt": [private_from(first, last) for first, last in spans]}

    def test_only_a_stretch_long_enough_to_be_a_break(self):
        summary = self.summary([9 * 60, 9 * 60 + 29], [14 * 60, 14 * 60 + 45])
        self.assertEqual(zyt.kept_out(summary, REPORT), [[14 * 60, 14 * 60 + 45]])

    def test_a_stretch_is_clipped_to_the_window(self):
        summary = self.summary([6 * 60, 8 * 60], [19 * 60 + 30, 23 * 60])
        kept = zyt.kept_out(summary, {**REPORT, "earliest": "07:00", "latest": "20:00"})
        # the morning stretch starts before the window and the evening one runs
        # past it; what is kept out is the half hour of each that is inside
        self.assertEqual(kept, [[7 * 60, 8 * 60], [19 * 60 + 30, 20 * 60]])
        # and a stretch clipped down to less than the floor is not kept out
        summary = self.summary([19 * 60 + 45, 23 * 60])
        self.assertEqual(zyt.kept_out(summary, {**REPORT, "earliest": "07:00", "latest": "20:00"}), [])

    def test_null_keeps_every_stretch_out(self):
        summary = self.summary([9 * 60, 9 * 60 + 2])
        self.assertEqual(zyt.kept_out(summary, {**REPORT, "skipPrivateMinutes": None}), [[9 * 60, 9 * 60 + 2]])

    def test_a_day_with_no_private_time_keeps_nothing_out(self):
        self.assertEqual(zyt.kept_out({}, REPORT), [])

    def test_the_floor_is_about_what_the_stretch_lasted_not_what_it_covers(self):
        # 09:10:30 to 09:40:20 is twenty-nine minutes and fifty seconds, drawn
        # over thirty-one minutes of the clock. It is not half an hour.
        nearly = {"privateAt": [{"from": 550, "to": 581, "first": 550 * 60, "last": 550 * 60 + 29 * 60 + 50}]}
        self.assertEqual(zyt.kept_out(nearly, REPORT), [])
        half = {"privateAt": [{"from": 550, "to": 581, "first": 550 * 60, "last": 550 * 60 + 30 * 60}]}
        self.assertEqual(zyt.kept_out(half, REPORT), [[550, 581]])


class Rooms(unittest.TestCase):
    def test_the_window_less_what_is_kept_out(self):
        report = {**REPORT, "earliest": "08:00", "latest": "18:00"}
        self.assertEqual(zyt.rooms(report, []), [[8 * 60, 18 * 60]])
        self.assertEqual(
            zyt.rooms(report, [[13 * 60, 14 * 60]]),
            [[8 * 60, 13 * 60], [14 * 60, 18 * 60]],
        )

    def test_a_stretch_over_an_end_of_the_window_shortens_it(self):
        report = {**REPORT, "earliest": "08:00", "latest": "18:00"}
        self.assertEqual(zyt.rooms(report, [[8 * 60, 9 * 60]]), [[9 * 60, 18 * 60]])
        self.assertEqual(zyt.rooms(report, [[17 * 60, 18 * 60]]), [[8 * 60, 17 * 60]])
        self.assertEqual(zyt.rooms(report, [[8 * 60, 18 * 60]]), [])


class Capacity(unittest.TestCase):
    def test_blocks_and_breaks_inside_the_window(self):
        self.assertEqual(zyt.capacity(REPORT), 12 * 60)  # 5h + 30' + 5h + 30' + 2h
        self.assertEqual(zyt.capacity({**REPORT, "latest": "12:00"}), 5 * 60)  # 5h window, one block
        self.assertEqual(zyt.capacity({**REPORT, "maxBlockMinutes": 60, "breakMinutes": 60}), 7 * 60)


class Layout(unittest.TestCase):
    def test_a_day_that_fits_keeps_its_own_start(self):
        summary = {"start": at("2026-09-14", "08:02")}
        blocks = zyt.layout(zyt.anchor(summary, REPORT), 7 * 60 + 55, REPORT)
        # the break is lunch, so the morning ends at the late end of the lunch
        # window rather than five hours after the day began
        self.assertEqual(blocks, [[8 * 60, 12 * 60 + 30], [13 * 60, 16 * 60 + 25]])

    def test_a_late_day_is_moved_earlier_as_a_whole(self):
        summary = {"start": at("2026-09-14", "14:00")}
        blocks = zyt.layout(zyt.anchor(summary, REPORT), 8 * 60, REPORT)
        self.assertEqual(blocks[-1][1], 20 * 60)
        self.assertEqual(blocks, [[11 * 60 + 30, 16 * 60 + 30], [17 * 60, 20 * 60]])

    def test_a_start_after_the_window_is_pulled_back_to_its_end(self):
        summary = {"start": at("2026-09-14", "21:15")}
        self.assertEqual(zyt.anchor(summary, REPORT), 20 * 60)
        self.assertEqual(zyt.layout(20 * 60, 60, REPORT), [[19 * 60, 20 * 60]])

    def test_a_day_without_a_start_uses_the_default(self):
        self.assertEqual(zyt.anchor({"start": None}, REPORT), 8 * 60)
        self.assertEqual(zyt.layout(8 * 60, 0, REPORT), [])


class PrivateUnderTheBooking(unittest.TestCase):
    def test_the_minutes_a_block_was_drawn_across(self):
        summary = {"privateAt": [private_from(9 * 60, 9 * 60 + 10), private_from(21 * 60, 21 * 60 + 30)]}
        blocks = [[8 * 60, 12 * 60], [13 * 60, 18 * 60]]
        # the morning sliver is under the first block; the evening one is after
        # the working day and under nothing
        self.assertEqual(zyt.private_under(summary, blocks), 10 * 60)

    def test_a_stretch_under_two_blocks_is_counted_once(self):
        summary = {"privateAt": [private_from(11 * 60, 14 * 60)]}
        blocks = [[8 * 60, 12 * 60], [13 * 60, 18 * 60]]
        # 11:00-12:00 and 13:00-14:00 are two hours of it, and the break
        # between the blocks is not under anything
        self.assertEqual(zyt.private_under(summary, blocks), 2 * 60 * 60)

    def test_it_is_never_longer_than_the_stretch_lasted(self):
        # drawn over two minutes of the clock, fifty seconds long
        summary = {"privateAt": [{"from": 9 * 60, "to": 9 * 60 + 2, "first": 9 * 3600, "last": 9 * 3600 + 50}]}
        self.assertEqual(zyt.private_under(summary, [[8 * 60, 12 * 60]]), 50)

    def test_two_blocks_over_one_minute_are_one_minute(self):
        # No layout hands these over, and the figure holds if one ever does.
        summary = {"privateAt": [private_from(10 * 60, 10 * 60 + 30)]}
        self.assertEqual(zyt.private_under(summary, [[10 * 60, 10 * 60 + 15], [10 * 60, 10 * 60 + 15]]), 15 * 60)

    def test_something_shorter_than_a_minute_says_so(self):
        self.assertEqual(zyt.fmt_small(59), "under a minute")
        self.assertEqual(zyt.fmt_small(60), "0h01")
        self.assertEqual(zyt.fmt_small(0), "under a minute")

    def test_the_report_says_under_a_minute_rather_than_nothing(self):
        days = week(mon=480)
        monday = dt.date(2026, 9, 14)
        days[monday]["privateAt"] = [{"from": 540, "to": 541, "first": 9 * 3600 + 30, "last": 9 * 3600 + 35}]
        blocks, booked, leftover = zyt.propose(days, REPORT)
        text = zyt.render_week(monday, days, blocks, booked, leftover)
        self.assertIn("under a minute of it is under a block", text)

    def test_a_second_over_a_block_boundary_is_a_second(self):
        # the block ends at 09:01, the stretch runs 09:00:59 to 09:01:59
        summary = {"privateAt": [{"from": 540, "to": 542, "first": 9 * 3600 + 59, "last": 9 * 3600 + 119}]}
        self.assertEqual(zyt.private_under(summary, [[8 * 60, 9 * 60 + 1]]), 1)

    def test_nothing_private_and_nothing_booked_are_both_zero(self):
        self.assertEqual(zyt.private_under({}, [[8 * 60, 12 * 60]]), 0)
        self.assertEqual(zyt.private_under({"privateAt": [private_from(9 * 60, 10 * 60)]}, []), 0)

    def test_a_stretch_kept_out_of_the_layout_is_under_no_block(self):
        report = {**REPORT, "earliest": "08:00", "latest": "20:00"}
        days = week(mon=480)
        monday = dt.date(2026, 9, 14)
        days[monday]["privateAt"] = [private_from(13 * 60, 14 * 60)]
        blocks, _, _ = zyt.propose(days, report)
        self.assertEqual(zyt.private_under(days[monday], blocks[monday]), 0)

    def test_the_report_says_it_under_the_totals(self):
        days = week(mon=480)
        monday = dt.date(2026, 9, 14)
        days[monday]["privateAt"] = [private_from(9 * 60, 9 * 60 + 10)]
        blocks, booked, leftover = zyt.propose(days, REPORT)
        text = zyt.render_week(monday, days, blocks, booked, leftover)
        self.assertIn("none of the private time is booked; 0h10 of it is under a block", text)
        # and a week with none of it says nothing at all
        days[monday]["privateAt"] = []
        text = zyt.render_week(monday, days, blocks, booked, leftover)
        self.assertNotIn("under a block", text)

    def test_the_json_carries_it_per_day(self):
        days = week(mon=480)
        monday = dt.date(2026, 9, 14)
        days[monday]["privateAt"] = [private_from(9 * 60, 9 * 60 + 10)]
        blocks, booked, leftover = zyt.propose(days, REPORT)
        shape = zyt.week_json(days, blocks, booked, leftover)
        self.assertEqual(shape["days"]["2026-09-14"]["privateUnderBooking"], 600)
        self.assertEqual(shape["days"]["2026-09-15"]["privateUnderBooking"], 0)


class LayoutAroundPrivate(unittest.TestCase):
    REPORT = {**REPORT, "earliest": "07:00", "latest": "20:00", "breakMinutes": 30}

    def test_the_blocks_go_round_a_private_hour(self):
        blocks = zyt.layout(8 * 60, 7 * 60 + 55, self.REPORT, [[14 * 60, 15 * 60]])
        self.assertEqual(blocks, [[480, 750], [780, 840], [900, 1045]])
        self.assertEqual(zyt.placed(blocks), 7 * 60 + 55)
        for start, end in blocks:
            self.assertFalse(end > 14 * 60 and start < 15 * 60)

    def test_a_private_stretch_over_lunch_is_the_lunch_break(self):
        blocks = zyt.layout(8 * 60, 7 * 60 + 55, self.REPORT, [[11 * 60 + 30, 12 * 60 + 30]])
        # no second break is asked for in the same hour
        self.assertEqual(blocks, [[480, 690], [750, 1015]])

    def test_a_gap_shorter_than_a_break_is_topped_up_after_it(self):
        blocks = zyt.layout(8 * 60, 6 * 60, self.REPORT, [[10 * 60, 10 * 60 + 10]])
        # ten minutes of the thirty the next block owes were spent in the gap,
        # so twenty are left and the block starts at 10:30
        self.assertEqual(blocks, [[480, 600], [630, 870]])

    def test_a_day_that_starts_inside_a_private_stretch_starts_after_it(self):
        self.assertEqual(zyt.layout(8 * 60, 4 * 60, self.REPORT, [[8 * 60, 9 * 60]]), [[540, 780]])

    def test_a_day_reaches_back_past_its_start_when_the_rest_cannot_hold_it(self):
        # nothing left after 17:00, and eight hours to place
        blocks = zyt.layout(17 * 60, 8 * 60, self.REPORT, [[18 * 60, 20 * 60]])
        self.assertEqual(zyt.placed(blocks), 8 * 60)
        self.assertLess(blocks[0][0], 17 * 60)

    def test_a_day_reaches_back_when_the_breaks_leave_too_little_room(self):
        # The rooms after the start add up to the hours and still cannot hold
        # them, because a break goes between every two blocks.
        report = {**REPORT, "earliest": "08:00", "latest": "18:00", "maxBlockMinutes": 60, "breakMinutes": 30}
        blocks = zyt.layout(13 * 60, 300, report, [[12 * 60, 12 * 60 + 30]])
        self.assertEqual(zyt.placed(blocks), 300)
        self.assertLess(blocks[0][0], 13 * 60)

    def test_what_cannot_be_placed_is_left_unplaced(self):
        blocks = zyt.layout(8 * 60, 12 * 60, self.REPORT, [[9 * 60, 19 * 60]])
        self.assertLess(zyt.placed(blocks), 12 * 60)

    def test_capacity_shrinks_by_what_is_kept_out(self):
        self.assertEqual(zyt.capacity(self.REPORT), 12 * 60)
        self.assertEqual(zyt.capacity(self.REPORT, [[13 * 60, 14 * 60]]), 11 * 60)
        self.assertEqual(zyt.capacity(self.REPORT, [[7 * 60, 20 * 60]]), 0)


def week(**hours):
    """A week from Monday 2026-09-14 with the given work minutes per weekday name."""
    monday = dt.date(2026, 9, 14)
    days = {}
    for i, name in enumerate(["mon", "tue", "wed", "thu", "fri", "sat", "sun"]):
        day = monday + dt.timedelta(days=i)
        mins = hours.get(name, 0)
        start = at(day.isoformat(), "09:00") if mins else None
        days[day] = {"start": start, "end": None, "work": mins * 60, "private": 0, "privateAt": [], "break": 0}
    return days


class ProposeAroundPrivate(unittest.TestCase):
    def test_a_private_afternoon_takes_the_hours_to_the_other_days(self):
        days = week(mon=600, tue=300, wed=300, thu=300, fri=300)
        monday = dt.date(2026, 9, 14)
        days[monday]["privateAt"] = [private_from(13 * 60, 18 * 60)]
        blocks, booked, leftover = zyt.propose(days, REPORT)
        self.assertEqual(leftover, 0)
        # Monday holds what is left of its window, and the rest of its hours
        # are dealt out with the other days' own
        self.assertEqual(zyt.placed(blocks[monday]), booked[monday])
        self.assertLess(booked[monday], 600)
        self.assertEqual(sum(booked.values()), 600 + 4 * 300)
        for start, end in blocks[monday]:
            self.assertFalse(end > 13 * 60 and start < 18 * 60)

    def test_a_day_that_was_private_all_day_books_nothing(self):
        days = week(mon=120, tue=300)
        monday = dt.date(2026, 9, 14)
        days[monday]["privateAt"] = [private_from(0, 24 * 60)]
        blocks, booked, leftover = zyt.propose(days, REPORT)
        self.assertEqual(blocks[monday], [])
        self.assertEqual(booked[monday], 0)
        self.assertEqual(sum(booked.values()), 420)
        self.assertEqual(leftover, 0)

    def test_minutes_no_day_could_place_are_offered_to_the_other_days(self):
        # Monday's afternoon is private, so its layout holds less than its
        # hours. What it cannot place is dealt out again rather than becoming
        # leftover while Tuesday still has room.
        report = {**REPORT, "earliest": "08:00", "latest": "18:00", "maxBlockMinutes": 60, "breakMinutes": 30}
        days = week(mon=300, tue=60)
        monday = dt.date(2026, 9, 14)
        days[monday]["privateAt"] = [private_from(12 * 60, 12 * 60 + 30)]
        days[monday]["start"] = at(monday.isoformat(), "13:00")
        blocks, booked, leftover = zyt.propose(days, report)
        self.assertEqual(sum(booked.values()) + leftover, 360)
        self.assertEqual(leftover, 0)
        for day, day_blocks in blocks.items():
            self.assertEqual(zyt.placed(day_blocks), booked[day])

    def test_a_sliver_leaves_the_day_as_it_was(self):
        days = week(mon=480, tue=480)
        monday = dt.date(2026, 9, 14)
        plain = zyt.propose({day: dict(summary) for day, summary in days.items()}, REPORT)
        days[monday]["privateAt"] = [private_from(10 * 60, 10 * 60 + 3)]
        self.assertEqual(zyt.propose(days, REPORT), plain)


class Propose(unittest.TestCase):
    def test_weekend_hours_go_to_the_workdays_with_the_fewest_first(self):
        days = week(mon=480, tue=480, wed=360, thu=480, fri=480, sat=120, sun=60)
        blocks, booked, leftover = zyt.propose(days, REPORT)
        self.assertEqual(leftover, 0)
        self.assertEqual(sum(booked.values()), 480 * 4 + 360 + 180)
        # Wednesday catches up to the others, then the rest is dealt round in turn.
        self.assertEqual(booked[dt.date(2026, 9, 16)], 480 + 15)
        self.assertEqual(booked[dt.date(2026, 9, 14)], 480 + 15)
        self.assertEqual(booked[dt.date(2026, 9, 18)], 480)
        self.assertNotIn(dt.date(2026, 9, 19), blocks)

    def test_a_workday_above_capacity_spills_over(self):
        days = week(mon=13 * 60, tue=300, wed=300, thu=300, fri=300)
        blocks, booked, leftover = zyt.propose(days, REPORT)
        self.assertEqual(booked[dt.date(2026, 9, 14)], 12 * 60)
        self.assertEqual(sum(booked.values()), 13 * 60 + 4 * 300)
        self.assertEqual(leftover, 0)
        for day_blocks in blocks.values():
            for start, end in day_blocks:
                self.assertLessEqual(end - start, 300)
                self.assertLessEqual(end, 20 * 60)
                self.assertGreaterEqual(start, 7 * 60)

    def test_what_finds_no_room_is_reported_not_dropped(self):
        days = week(sat=600)
        blocks, booked, leftover = zyt.propose(days, REPORT)
        self.assertEqual(leftover, 600)
        self.assertEqual(sum(booked.values()), 0)
        blocks, booked, leftover = zyt.propose(days, {**REPORT, "fillEmptyDays": True})
        self.assertEqual(leftover, 0)
        self.assertEqual(sum(booked.values()), 600)
        self.assertEqual(booked[dt.date(2026, 9, 14)], 120)

    def test_the_total_is_kept_to_the_minute(self):
        days = week(mon=463, tue=511, wed=0, thu=299, fri=612, sat=187, sun=44)
        _, booked, leftover = zyt.propose(days, REPORT)
        self.assertEqual(sum(booked.values()) + leftover, 463 + 511 + 299 + 612 + 187 + 44)


class Rendering(unittest.TestCase):
    def test_week_parsing_and_naming(self):
        self.assertEqual(zyt.parse_week("2026-W38"), dt.date(2026, 9, 14))
        self.assertEqual(zyt.parse_week("2026-w01"), dt.date(2025, 12, 29))
        self.assertEqual(zyt.week_of(dt.date(2026, 9, 20)), "2026-W38")

    def test_formatting(self):
        self.assertEqual(zyt.fmt_h(7 * 3600 + 55 * 60 + 59), "7h55")
        self.assertEqual(zyt.fmt_m(0), "0h00")
        self.assertEqual(zyt.clock(16 * 60 + 5), "16:05")

    def test_the_week_renders_every_day_and_a_total(self):
        days = week(mon=480, sat=60)
        blocks, booked, leftover = zyt.propose(days, REPORT)
        text = zyt.render_week(dt.date(2026, 9, 14), days, blocks, booked, leftover)
        self.assertIn("Week 2026-W38", text)
        self.assertIn("Mon 14.09.", text)
        self.assertIn("moved to the workdays", text)
        self.assertIn("booked 9h00", text)
        self.assertIn("left over 0h00", text)
        as_json = zyt.week_json(days, blocks, booked, leftover)
        self.assertEqual(as_json["days"]["2026-09-14"]["booked"], 9 * 3600)
        self.assertEqual(as_json["leftover"], 0)


class Calendar(unittest.TestCase):
    def settings(self, **over):
        settings = dict(zyt.MEETING_DEFAULTS)
        settings.update({"enabled": True, "tenantId": "tenant", "clientId": "client"})
        settings.update(over)
        return settings

    def test_the_rules_fill_the_calendar_block(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "rules.json"
            path.write_text(json.dumps({"meetings": {"enabled": True, "class": "private"}}))
            rules = zyt.load_rules(path)
            self.assertEqual(rules["meetings"]["class"], "private")
            self.assertEqual(rules["meetings"]["statuses"], ["busy", "oof", "tentative"])
            self.assertFalse(zyt.load_rules(Path(tmp) / "none.json")["meetings"]["enabled"])

    def test_a_calendar_without_an_app_says_what_is_missing(self):
        with self.assertRaises(SystemExit) as off:
            zyt.meeting_settings({"meetings": dict(zyt.MEETING_DEFAULTS)})
        self.assertIn("enabled", str(off.exception))
        with self.assertRaises(SystemExit) as bare:
            zyt.meeting_settings({"meetings": dict(zyt.MEETING_DEFAULTS, enabled=True)})
        self.assertIn("tenantId", str(bare.exception))

    def test_graph_dates_become_epoch_seconds(self):
        moment = zyt._epoch({"dateTime": "2026-09-30T13:00:00.0000000", "timeZone": "UTC"})
        self.assertEqual(dt.datetime.fromtimestamp(moment, dt.timezone.utc).hour, 13)
        # an event that comes back in another zone is read in that zone, since
        # an all-day event or a calendar of its own can answer in one
        zurich = zyt._epoch({"dateTime": "2026-09-30T13:00:00.0000000", "timeZone": "Europe/Zurich"})
        self.assertEqual(dt.datetime.fromtimestamp(zurich, dt.timezone.utc).hour, 11)
        # and a zone this machine cannot name leaves that one event out rather
        # than taking the rest of the day with it
        with contextlib.redirect_stderr(io.StringIO()) as said:
            self.assertEqual(
                zyt._epoch({"dateTime": "2026-09-30T13:00:00.0000000", "timeZone": "W. Europe Standard Time"}), 0
            )
        self.assertIn("W. Europe Standard Time", said.getvalue())
        self.assertEqual(zyt._epoch(None), 0)
        self.assertEqual(zyt._epoch({"dateTime": "the day after tomorrow"}), 0)

    def test_the_calendar_is_asked_for_times_and_nothing_else(self):
        answer = json.dumps(
            {
                "value": [
                    {
                        "start": {"dateTime": "2026-09-30T08:00:00.0000000", "timeZone": "UTC"},
                        "end": {"dateTime": "2026-09-30T09:00:00.0000000", "timeZone": "UTC"},
                        "isAllDay": False,
                        "isCancelled": False,
                        "showAs": "busy",
                        "responseStatus": {"response": "accepted"},
                    },
                    {"start": None, "end": None},
                ]
            }
        ).encode()
        seen = {}

        class Fake:
            def __enter__(self):
                return self

            def __exit__(self, *_):
                return False

            def read(self):
                return answer

        def urlopen(request, timeout=None):
            seen["url"] = request.full_url
            seen["auth"] = request.headers["Authorization"]
            seen["prefer"] = request.headers["Prefer"]
            return Fake()

        with mock.patch.object(zyt.urllib.request, "urlopen", urlopen):
            events = zyt.calendar_view(self.settings(), 1790000000, 1790003600, token="a-token")
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["status"], "busy")
        self.assertEqual(events[0]["response"], "accepted")
        self.assertEqual(events[0]["end"] - events[0]["start"], 3600)
        self.assertIn("calendarView", seen["url"])
        self.assertEqual(seen["auth"], "Bearer a-token")
        # the times are read as UTC, so the answer is pinned to it
        self.assertEqual(seen["prefer"], 'outlook.timezone="UTC"')
        # the subject is asked for, because `skipSubjects` decides on it, and
        # it goes no further than that decision
        self.assertNotIn("subject", json.dumps(events))
        for field in ("attendees", "body", "location"):
            self.assertNotIn(field, seen["url"])

    def test_every_page_of_a_long_window_is_read(self):
        def page(hour, nxt=None):
            body = {
                "value": [
                    {
                        "start": {"dateTime": f"2026-09-30T{hour:02d}:00:00.0000000", "timeZone": "UTC"},
                        "end": {"dateTime": f"2026-09-30T{hour:02d}:30:00.0000000", "timeZone": "UTC"},
                        "showAs": "busy",
                    }
                ]
            }
            if nxt:
                body["@odata.nextLink"] = nxt
            return json.dumps(body).encode()

        pages = [page(8, "https://graph.microsoft.com/v1.0/me/calendarView?$skiptoken=two"), page(9)]
        asked = []

        class Fake:
            def __init__(self, body):
                self.body = body

            def __enter__(self):
                return self

            def __exit__(self, *_):
                return False

            def read(self):
                return self.body

        def urlopen(request, timeout=None):
            asked.append(request.full_url)
            return Fake(pages[len(asked) - 1])

        with mock.patch.object(zyt.urllib.request, "urlopen", urlopen):
            events = zyt.calendar_view(self.settings(), 1790000000, 1790600000, token="a-token")
        # Graph says there is more in @odata.nextLink rather than by failing, so
        # a window with more events than one page holds must not lose the rest
        self.assertEqual(len(events), 2)
        self.assertEqual(len(asked), 2)
        self.assertIn("skiptoken=two", asked[1])

    def test_the_sign_in_waits_for_the_answer_and_not_for_the_favicon(self):
        # A port the machine says is free, rather than one this test hopes is:
        # a fixed number is taken sooner or later, and the failure then looks
        # like a broken sign-in instead of a busy port.
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            port = probe.getsockname()[1]
        settings = self.settings(redirectUri=f"http://localhost:{port}")
        stored = {}
        exchanged = {}
        opened = {}

        def token_request(_settings, form):
            exchanged.update(form)
            return {"refresh_token": "a-refresh-token"}

        with (
            mock.patch.object(zyt, "_token_request", token_request),
            mock.patch.object(zyt, "keychain", lambda account, secret=None: stored.update({account: secret})),
            mock.patch.object(zyt.subprocess, "run", lambda args, **_kw: opened.update({"url": args[-1]})),
        ):

            def quietly():
                with contextlib.redirect_stdout(io.StringIO()):
                    zyt.sign_in(settings)

            signing = threading.Thread(target=quietly, daemon=True)
            signing.start()
            deadline = time.time() + 20

            def knock(path):
                while time.time() < deadline:
                    try:
                        with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=5) as answer:
                            return answer.status
                    except OSError:
                        time.sleep(0.1)
                return None

            try:
                # The browser asks for the favicon of the page it was just
                # shown, and a server that handles one request would have taken
                # that for the answer and failed on a missing state.
                self.assertEqual(knock("/favicon.ico"), 200)
                self.assertTrue(signing.is_alive())

                state = urllib.parse.parse_qs(urllib.parse.urlparse(opened["url"]).query)["state"][0]
                self.assertEqual(knock(f"/?code=the-code&state={state}"), 200)
            finally:
                # Whatever happened above, the thread ends inside the patches:
                # loose, it would reach the real keychain. After the callback it
                # is already on its way out, so it is given a moment first; only
                # a thread still waiting needs to be told to stop.
                signing.join(timeout=5)
                if signing.is_alive():
                    knock("/?error=stop")
                    signing.join(timeout=20)

        self.assertFalse(signing.is_alive())
        self.assertEqual(exchanged.get("code"), "the-code")
        self.assertEqual(exchanged.get("grant_type"), "authorization_code")
        self.assertEqual(stored, {"client": "a-refresh-token"})

    def test_a_subject_on_the_skip_list_never_becomes_an_hour(self):
        settings = self.settings(skipSubjects=["social event", "bier"])
        self.assertTrue(zyt.skipped(settings, "CON & Friends Social Event"))
        self.assertTrue(zyt.skipped(settings, "Feierabendbier"))
        self.assertFalse(zyt.skipped(settings, "Architecture board"))
        self.assertFalse(zyt.skipped(settings, None))
        # an empty list is no list, and nothing is skipped by accident
        self.assertFalse(zyt.skipped(self.settings(), "CON & Friends Social Event"))

    def test_the_skipped_events_are_counted_and_never_named(self):
        answer = json.dumps(
            {
                "value": [
                    {
                        "start": {"dateTime": "2026-09-30T08:00:00.0000000", "timeZone": "UTC"},
                        "end": {"dateTime": "2026-09-30T09:00:00.0000000", "timeZone": "UTC"},
                        "showAs": "busy",
                        "subject": "CON & Friends Social Event",
                    },
                    {
                        "start": {"dateTime": "2026-09-30T10:00:00.0000000", "timeZone": "UTC"},
                        "end": {"dateTime": "2026-09-30T11:00:00.0000000", "timeZone": "UTC"},
                        "showAs": "busy",
                        "subject": "Architecture board",
                    },
                ]
            }
        ).encode()

        class Fake:
            def __enter__(self):
                return self

            def __exit__(self, *_):
                return False

            def read(self):
                return answer

        with (
            mock.patch.object(zyt.urllib.request, "urlopen", lambda *_a, **_kw: Fake()),
            contextlib.redirect_stderr(io.StringIO()) as said,
        ):
            events = zyt.calendar_view(
                self.settings(skipSubjects=["social event"]), 1790000000, 1790003600, token="a-token"
            )
        self.assertEqual(len(events), 1)
        self.assertEqual(json.dumps(events).count("subject"), 0)
        # it says how many it left out and not a word about what they were
        self.assertIn("1 event left out", said.getvalue())
        self.assertNotIn("Social", said.getvalue())

    def test_the_newest_refresh_token_is_the_one_kept(self):
        stored = {"client": "old-refresh"}

        def keychain(account, secret=None):
            if secret is None:
                return stored.get(account)
            stored[account] = secret
            return secret

        with (
            mock.patch.object(zyt, "keychain", keychain),
            mock.patch.object(
                zyt, "_token_request", return_value={"access_token": "fresh", "refresh_token": "new-refresh"}
            ),
        ):
            self.assertEqual(zyt.graph_token(self.settings()), "fresh")
        # Entra hands out a new one on every use and lets the old one lapse
        self.assertEqual(stored["client"], "new-refresh")

    def test_without_a_sign_in_it_says_so(self):
        with mock.patch.object(zyt, "keychain", lambda *_args, **_kw: None), self.assertRaises(SystemExit) as told:
            zyt.graph_token(self.settings())
        self.assertIn("zyt login", str(told.exception))


class Lunch(unittest.TestCase):
    def report(self, **over):
        report = dict(zyt.REPORT_DEFAULTS)
        report.update(over)
        return report

    def blocks(self, start, total, **over):
        return [
            f"{s // 60:02d}:{s % 60:02d}-{e // 60:02d}:{e % 60:02d}"
            for s, e in zyt.layout(start, total, self.report(**over))
        ]

    def test_the_break_is_taken_at_midday(self):
        # a day that started at nine used to break in the middle of the
        # afternoon, because the break fell wherever the first block ended
        self.assertEqual(self.blocks(9 * 60, 470, breakMinutes=60), ["09:00-12:00", "13:00-17:50"])
        self.assertEqual(self.blocks(7 * 60 + 30, 510, breakMinutes=60), ["07:30-12:00", "13:00-17:00"])

    def test_a_block_is_never_stretched_to_reach_the_window(self):
        # four hours from seven ends at eleven, before lunch could start, and
        # the block keeps its length rather than growing to 11:15
        blocks = zyt.layout(7 * 60, 600, self.report(breakMinutes=60, maxBlockMinutes=240))
        self.assertEqual(blocks[0][1] - blocks[0][0], 240)
        for start, end in blocks:
            self.assertLessEqual(end - start, 240)

    def test_a_morning_too_short_to_pay_for_itself_is_not_taken(self):
        # a day that starts at noon would have a half-hour morning, and the
        # rest would need one block more than the day was measured for: one
        # break more than the window was given, and the whole day pushed out of
        # it. The ordinary layout holds instead.
        report = self.report()
        blocks = zyt.layout(12 * 60, 720, report)
        self.assertGreaterEqual(blocks[0][0], zyt.minutes(report["earliest"]))
        self.assertEqual(blocks[-1][1], zyt.minutes(report["latest"]))
        self.assertEqual(sum(end - start for start, end in blocks), 720)

    def test_lunch_is_placed_against_the_start_the_day_ends_up_with(self):
        # 700 minutes from nine runs to 21:40 and is pulled back by an hour and
        # forty, which used to drag lunch to 10:50 with it
        report = self.report()
        blocks = zyt.layout(9 * 60, 700, report)
        self.assertEqual(sum(end - start for start, end in blocks), 700)
        self.assertLessEqual(blocks[-1][1], zyt.minutes(report["latest"]))
        if len(blocks) > 1:
            first_break = blocks[0][1]
            self.assertGreaterEqual(first_break, zyt.minutes(report["lunch"]["earliest"]))
            self.assertLessEqual(first_break + report["breakMinutes"], zyt.minutes(report["lunch"]["latest"]))

    def test_a_day_that_cannot_fit_the_window_is_moved_as_a_whole(self):
        # twelve hours of work and two breaks need more than the window holds,
        # so something has to give: every block and every break keeps its
        # length, the day ends at the latest hour, and lunch moves with it
        report = self.report(breakMinutes=60)
        blocks = zyt.layout(9 * 60, 720, report)
        self.assertEqual(sum(end - start for start, end in blocks), 720)
        self.assertEqual(blocks[-1][1], zyt.minutes(report["latest"]))
        for first, second in zip(blocks, blocks[1:]):
            self.assertEqual(second[0] - first[1], 60)

    def test_a_day_with_no_room_for_one_keeps_its_shape(self):
        # short enough to need no break at all
        self.assertEqual(self.blocks(8 * 60, 240), ["08:00-12:00"])
        # and a day that starts after the window has gone by, which is then
        # pulled back as a whole because it would run past the latest hour
        self.assertEqual(self.blocks(13 * 60 + 30, 420, breakMinutes=60), ["12:00-17:00", "18:00-20:00"])

    def test_without_a_lunch_window_it_is_as_it_was(self):
        self.assertEqual(self.blocks(9 * 60, 470, breakMinutes=60, lunch=None), ["09:00-14:00", "15:00-17:50"])

    def test_every_booked_minute_is_still_in_a_block(self):
        for total in (60, 300, 301, 470, 600, 780):
            blocks = zyt.layout(9 * 60, total, self.report(breakMinutes=60))
            self.assertEqual(sum(end - start for start, end in blocks), total)


class Rules(unittest.TestCase):
    def test_defaults_without_a_file_and_the_report_merged_over_them(self):
        with tempfile.TemporaryDirectory() as tmp:
            rules = zyt.load_rules(Path(tmp) / "missing.json")
            self.assertEqual(rules["report"], zyt.REPORT_DEFAULTS)
            path = Path(tmp) / "rules.json"
            path.write_text(json.dumps({"report": {"latest": "18:00"}}))
            rules = zyt.load_rules(path)
            self.assertEqual(rules["report"]["latest"], "18:00")
            self.assertEqual(rules["report"]["earliest"], "07:00")

    def test_a_broken_file_is_a_message_not_a_traceback(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "rules.json"
            path.write_text("{not json")
            with self.assertRaises(SystemExit):
                zyt.load_rules(path)
            path.write_text(json.dumps({"report": [1, 2]}))
            with self.assertRaises(SystemExit):
                zyt.load_rules(path)
            path.write_text(json.dumps([]))
            with self.assertRaises(SystemExit):
                zyt.load_rules(path)


class DayView(unittest.TestCase):
    def test_a_single_day_has_its_own_title_and_no_week_leftover(self):
        days = week(mon=480, sat=600)
        blocks, booked, _ = zyt.propose(days, REPORT)
        monday = dt.date(2026, 9, 14)
        text = zyt.render_week(monday, {monday: days[monday]}, blocks, booked, None, "Monday 14.09.2026")
        self.assertTrue(text.startswith("Monday 14.09.2026"))
        self.assertNotIn("left over", text)
        self.assertNotIn("Sat", text)
        as_json = zyt.week_json({monday: days[monday]}, blocks, booked, None)
        self.assertIsNone(as_json["leftover"])
        self.assertEqual(list(as_json["days"]), ["2026-09-14"])

    def test_the_totals_add_up_to_the_rows_in_whole_minutes(self):
        days = week()
        for i in range(5):
            day = dt.date(2026, 9, 14) + dt.timedelta(days=i)
            days[day]["work"] = 8 * 3600 + 50
            days[day]["start"] = at(day.isoformat(), "08:00")
        blocks, booked, leftover = zyt.propose(days, REPORT)
        text = zyt.render_week(dt.date(2026, 9, 14), days, blocks, booked, leftover)
        self.assertIn("recorded 40h00 work", text)
        self.assertIn("booked 40h00", text)


class ReportCommand(unittest.TestCase):
    def test_week_and_day_run_end_to_end_on_a_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            state, config = zyt.STATE, zyt.CONFIG
            zyt.STATE = Path(tmp) / "state"
            zyt.CONFIG = Path(tmp) / "rules.json"
            zyt.STATE.mkdir()
            (zyt.STATE / "intervals.csv").write_text(
                "start,end,seconds,class,source,app\n"
                "2026-09-14T08:00:00+02:00,2026-09-14T12:00:00+02:00,14400,work,app,Mail\n"
                "2026-09-19T14:00:00+02:00,2026-09-19T15:00:00+02:00,3600,work,app,Mail\n"
            )
            out = zyt.sys.stdout
            try:
                zyt.sys.stdout = io.StringIO()
                self.assertEqual(zyt.main(["week", "2026-W38"]), 0)
                text = zyt.sys.stdout.getvalue()
                self.assertIn("Week 2026-W38", text)
                self.assertIn("recorded 5h00 work", text)
                self.assertIn("booked 5h00", text)
                zyt.sys.stdout = io.StringIO()
                self.assertEqual(zyt.main(["day", "2026-09-14", "--json"]), 0)
                data = json.loads(zyt.sys.stdout.getvalue())
                self.assertEqual(list(data["days"]), ["2026-09-14"])
                self.assertEqual(data["days"]["2026-09-14"]["booked"], 5 * 3600)
                self.assertIsNone(data["leftover"])
            finally:
                zyt.sys.stdout = out
                zyt.STATE, zyt.CONFIG = state, config

    def test_a_date_that_is_not_one_is_said_in_a_line(self):
        for when, single, wants in (
            ("2026-13-01", True, "a day, YYYY-MM-DD"),
            ("2026-W99", False, "a week, YYYY-Www"),
            ("2026-09-14", False, "a week, YYYY-Www"),
        ):
            with self.assertRaises(SystemExit) as caught:
                zyt.period(when, single)
            self.assertEqual(str(caught.exception), f"{when}: no such date; it wants {wants}")


class Board(unittest.TestCase):
    def test_the_scale_is_the_window_widened_around_what_lies_outside_it(self):
        self.assertEqual(zyt.scale({}, {}, REPORT), (7, 20))
        late = {dt.date(2026, 9, 20): [seg("2026-09-20", "21:00", "23:40")]}
        self.assertEqual(zyt.scale(late, {}, REPORT), (7, 24))
        early = {dt.date(2026, 9, 20): [seg("2026-09-20", "05:20", "06:00")]}
        self.assertEqual(zyt.scale(early, {}, REPORT), (5, 20))

    def test_a_segment_cut_at_midnight_reaches_the_end_of_its_day(self):
        self.assertEqual(zyt.span_of(seg("2026-09-19", "23:30", "00:00")), (23 * 60 + 30, 24 * 60))

    def test_a_run_of_one_class_is_drawn_as_one_bar(self):
        run = [
            seg("2026-09-14", "09:00", "09:01"),
            seg("2026-09-14", "09:01", "09:02"),
            seg("2026-09-14", "09:02", "09:03", "private"),
            seg("2026-09-14", "10:30", "11:00"),
        ]
        drawn = [(s.start.strftime("%H:%M"), s.end.strftime("%H:%M"), s.cls) for s in zyt.joined(run)]
        self.assertEqual(drawn, [("09:00", "09:02", "work"), ("09:02", "09:03", "private"), ("10:30", "11:00", "work")])
        self.assertEqual(run[0].end, at("2026-09-14", "09:01"))  # the rows themselves are left alone

    def test_the_board_draws_both_lanes_and_fetches_nothing(self):
        days = week(mon=480, sat=60)
        blocks, booked, leftover = zyt.propose(days, REPORT)
        segments = {day: [] for day in days}
        segments[dt.date(2026, 9, 14)] = [seg("2026-09-14", "09:00", "17:00")]
        drawn = zyt.board_week(
            days, segments, blocks, booked, leftover, REPORT, "Week 2026-W38", "14.09. to 20.09.", "w2026-W38"
        )
        page = zyt.render_board([drawn], "Week 2026-W38")
        self.assertTrue(page.startswith("<!doctype html>"))
        self.assertIn('title="work 09:00 to 17:00, 8h00"', page)  # the recorded lane
        self.assertIn('title="book 09:00 to 12:30, 3h30"', page)  # and the proposal below it
        self.assertIn("in a meeting", page)  # and the lane the calendar fills has a key
        self.assertIn("moved to the workdays", page)
        for absent in ("<script", "http", "<img"):
            self.assertNotIn(absent, page)

    def test_the_meetings_have_a_lane_of_their_own(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "intervals.csv"
            path.write_text(
                "start,end,seconds,class,source,app\n"
                "2026-09-14T09:00:00+02:00,2026-09-14T10:00:00+02:00,3600,work,app,Code\n"
                "2026-09-14T10:00:00+02:00,2026-09-14T11:00:00+02:00,3600,work,meeting,calendar\n"
            )
            page = zyt.drawn_week(zyt.read_intervals(path), dt.date(2026, 9, 14), dict(zyt.REPORT_DEFAULTS))
        # an hour at the keyboard and an hour in a meeting are both work and
        # are not the same thing to look at, so they do not share a bar
        self.assertIn('title="work 09:00 to 10:00, 1h00"', page)
        self.assertIn('class="meeting"', page)
        self.assertIn('title="meeting 10:00 to 11:00, 1h00"', page)

    def test_a_bar_with_no_whole_minute_in_it_says_its_seconds(self):
        self.assertEqual(zyt.said(seg("2026-09-14", "09:00", "17:00")), "work 09:00 to 17:00, 8h00")
        moment = at("2026-09-14", "00:27")
        flicker = zyt.Segment(moment, moment + dt.timedelta(seconds=20), "private")
        self.assertEqual(zyt.said(flicker), "private 00:27:00, 20s")

    def test_the_board_command_writes_the_file_it_is_given(self):
        with tempfile.TemporaryDirectory() as tmp:
            state, config, out = zyt.STATE, zyt.CONFIG, zyt.sys.stdout
            zyt.STATE = Path(tmp) / "state"
            zyt.CONFIG = Path(tmp) / "rules.json"
            zyt.STATE.mkdir()
            (zyt.STATE / "intervals.csv").write_text(
                "start,end,seconds,class,source,app\n"
                "2026-09-14T08:00:00+02:00,2026-09-14T12:00:00+02:00,14400,work,app,Mail\n"
            )
            page = Path(tmp) / "not" / "there" / "yet.html"
            try:
                zyt.sys.stdout = io.StringIO()
                self.assertEqual(zyt.main(["board", "2026-W38", "--out", str(page), "--no-open"]), 0)
                self.assertEqual(zyt.sys.stdout.getvalue().strip(), str(page))
                self.assertIn("Week 2026-W38", page.read_text())
                # a date rather than a week, and the day is on its own
                self.assertEqual(zyt.main(["board", "2026-09-14", "--out", str(page), "--no-open"]), 0)
                drawn = page.read_text()
                self.assertIn("Monday 14.09.2026", drawn)
                self.assertNotIn("left over", drawn)
                self.assertNotIn("Tue", drawn)
            finally:
                zyt.sys.stdout = out
                zyt.STATE, zyt.CONFIG = state, config

    def test_the_weeks_run_from_the_first_recorded_to_the_last(self):
        grouped = zyt.by_week([seg("2026-09-14", "09:00", "17:00"), seg("2026-09-28", "09:00", "17:00")])
        weeks = [zyt.week_of(day) for day in zyt.board_weeks(grouped, dt.date(2026, 9, 21))]
        self.assertEqual(weeks, ["2026-W38", "2026-W39", "2026-W40"])  # W39 is empty and still in the row
        asked = [zyt.week_of(day) for day in zyt.board_weeks(grouped, dt.date(2026, 10, 12))]
        self.assertEqual(asked, ["2026-W38", "2026-W39", "2026-W40", "2026-W41", "2026-W42"])
        self.assertEqual([zyt.week_of(d) for d in zyt.board_weeks({}, dt.date(2026, 9, 21))], ["2026-W39"])
        over = zyt.by_week([seg("2026-09-20", "23:30", "00:30")])  # the half hour after midnight is a week on
        self.assertEqual(
            [zyt.week_of(d) for d in zyt.board_weeks(over, dt.date(2026, 9, 14))], ["2026-W38", "2026-W39"]
        )
        self.assertEqual(sorted(len(rows) for rows in over.values()), [1, 1])  # and it is filed in that week

    def test_the_arrows_move_between_the_weeks_in_the_file(self):
        with tempfile.TemporaryDirectory() as tmp:
            state, config, out = zyt.STATE, zyt.CONFIG, zyt.sys.stdout
            zyt.STATE = Path(tmp) / "state"
            zyt.CONFIG = Path(tmp) / "rules.json"
            zyt.STATE.mkdir()
            (zyt.STATE / "intervals.csv").write_text(
                "start,end,seconds,class,source,app\n"
                "2026-09-14T08:00:00+02:00,2026-09-14T12:00:00+02:00,14400,work,app,Mail\n"
                "2026-09-21T08:00:00+02:00,2026-09-21T12:00:00+02:00,14400,work,app,Mail\n"
            )
            page = Path(tmp) / "board.html"
            try:
                zyt.sys.stdout = io.StringIO()
                self.assertEqual(zyt.main(["board", "2026-W39", "--out", str(page), "--no-open"]), 0)
                drawn = page.read_text()
                self.assertIn('<section class="week" id="w2026-W38">', drawn)
                self.assertIn('<section class="week current" id="w2026-W39">', drawn)
                self.assertIn('href="#w2026-W38"', drawn)  # back out of the week on show
                self.assertEqual(drawn.count("nothing earlier"), 1)  # and no link off either end
                self.assertEqual(drawn.count("nothing later"), 1)
                self.assertNotIn("<script", drawn)
                # one day is asked for by name, so it is alone in the file and has no arrows
                self.assertEqual(zyt.main(["board", "2026-09-21", "--out", str(page), "--no-open"]), 0)
                alone = page.read_text()
                self.assertEqual(alone.count('<section class="week'), 1)
                self.assertNotIn("<nav>", alone)
                # and a week on its own when the file is going to somebody else
                self.assertEqual(zyt.main(["board", "2026-W39", "--one-week", "--out", str(page), "--no-open"]), 0)
                only = page.read_text()
                self.assertIn('<section class="week current" id="w2026-W39">', only)
                self.assertNotIn("w2026-W38", only)
                self.assertNotIn("<nav>", only)
            finally:
                zyt.sys.stdout = out
                zyt.STATE, zyt.CONFIG = state, config

    def test_a_browser_that_would_not_start_is_said_in_a_line(self):
        with tempfile.TemporaryDirectory() as tmp:
            state, config, out, err = zyt.STATE, zyt.CONFIG, zyt.sys.stdout, zyt.sys.stderr
            run = zyt.subprocess.run
            zyt.STATE = Path(tmp) / "state"
            zyt.CONFIG = Path(tmp) / "rules.json"
            zyt.STATE.mkdir()
            (zyt.STATE / "intervals.csv").write_text(
                "start,end,seconds,class,source,app\n"
                "2026-09-14T08:00:00+02:00,2026-09-14T12:00:00+02:00,14400,work,app,Mail\n"
            )
            page = Path(tmp) / "board.html"
            asked = []

            def refused(argv, **_):
                asked.append(argv)
                return zyt.subprocess.CompletedProcess(argv, 1)

            try:
                zyt.sys.stdout, zyt.sys.stderr = io.StringIO(), io.StringIO()
                zyt.subprocess.run = refused
                self.assertEqual(zyt.main(["board", "2026-W38", "--out", str(page)]), 0)
                self.assertEqual(asked, [["open", str(page)]])
                self.assertIn("could not open it", zyt.sys.stderr.getvalue())
                # one that did start leaves stderr empty
                zyt.subprocess.run = lambda argv, **_: zyt.subprocess.CompletedProcess(argv, 0)
                zyt.sys.stderr = io.StringIO()
                self.assertEqual(zyt.main(["board", "2026-W38", "--out", str(page)]), 0)
                self.assertEqual(zyt.sys.stderr.getvalue(), "")
            finally:
                zyt.sys.stdout, zyt.sys.stderr, zyt.subprocess.run = out, err, run
                zyt.STATE, zyt.CONFIG = state, config


class Intervals(unittest.TestCase):
    def test_rows_are_read_and_bad_ones_skipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "intervals.csv"
            path.write_text(
                "start,end,seconds,class,source,app\n"
                "2026-09-14T08:00:00+02:00,2026-09-14T09:00:00+02:00,3600,work,app,Mail\n"
                "2026-09-14T09:00:00+02:00,2026-09-14T09:00:00+02:00,0,work,app,Mail\n"
                "nonsense,2026-09-14T09:00:00+02:00,0,work,app,Mail\n"
                "2026-09-14T09:00:00+02:00,2026-09-14T09:10:00+02:00,600,other,app,X\n"
            )
            rows = zyt.read_intervals(path)
            self.assertEqual(len(rows), 1)
            self.assertEqual(rows[0].seconds, 3600)
            self.assertEqual(zyt.read_intervals(Path(tmp) / "missing.csv"), [])


class HookDirectory(unittest.TestCase):
    def test_the_file_a_tool_touches_wins_over_the_working_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            inside = Path(tmp) / "repo" / "src"
            inside.mkdir(parents=True)
            payload = {"cwd": "/somewhere/else", "tool_input": {"file_path": str(inside / "main.go")}}
            self.assertEqual(zyt.hook_directory(payload), str(inside))
            payload = {"cwd": tmp, "tool_input": {"file_path": str(inside / "new" / "deeper" / "file.py")}}
            self.assertEqual(zyt.hook_directory(payload), str(inside))
            payload = {"cwd": tmp, "tool_input": {"command": "ls"}}
            self.assertEqual(zyt.hook_directory(payload), tmp)
            self.assertEqual(zyt.hook_directory("garbage"), os.getcwd())


class Hook(unittest.TestCase):
    def test_the_note_is_written_whole_and_names_the_remote(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state"
            note = zyt.write_context("claude-code", tmp, state)
            written = json.loads((state / "context.json").read_text())
            self.assertEqual(written, note)
            self.assertEqual(written["source"], "claude-code")
            self.assertEqual(written["cwd"], tmp)
            self.assertIsNone(written["remote"])
            self.assertEqual([path.name for path in state.iterdir()], ["context.json"])

    def test_the_note_names_the_application_hosting_the_tool(self):
        with tempfile.TemporaryDirectory() as tmp:
            before = os.environ.get("__CFBundleIdentifier")
            os.environ["__CFBundleIdentifier"] = "com.example.Editor"
            try:
                note = zyt.write_context("claude-code", tmp, Path(tmp) / "state")
            finally:
                if before is None:
                    del os.environ["__CFBundleIdentifier"]
                else:
                    os.environ["__CFBundleIdentifier"] = before
            self.assertEqual(note["bundle"], "com.example.Editor")

    def test_a_prompt_also_marks_the_chat_being_talked_to(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = zyt.STATE
            zyt.STATE = Path(tmp) / "state"
            stdin, stdout = zyt.sys.stdin, zyt.sys.stdout
            try:
                zyt.sys.stdout = io.StringIO()
                zyt.sys.stdin = io.StringIO(
                    json.dumps({"cwd": tmp, "hook_event_name": "PostToolUse", "session_id": "a"})
                )
                zyt.main(["hook", "claude-code"])
                self.assertFalse((zyt.STATE / "chat.json").exists())
                zyt.sys.stdin = io.StringIO(
                    json.dumps({"cwd": tmp, "hook_event_name": "UserPromptSubmit", "session_id": "b"})
                )
                zyt.main(["hook", "claude-code"])
                chat = json.loads((zyt.STATE / "chat.json").read_text())
                self.assertEqual(chat["session"], "b")
                self.assertEqual(json.loads((zyt.STATE / "context.json").read_text())["session"], "b")
                self.assertEqual(zyt.sys.stdout.getvalue(), "")
            finally:
                zyt.sys.stdin, zyt.sys.stdout = stdin, stdout
                zyt.STATE = state

    def test_a_session_note_remembers_the_repository_it_last_touched(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state"
            first = zyt.write_session("claude-code", tmp, "abc", True, remote="git@host:me/one.git", state=state)
            self.assertEqual(first["promptAt"], first["at"])
            # a prompt in a folder full of checkouts resolves to nothing, and the
            # repository this session is in is still the one it was in
            later = zyt.write_session("claude-code", tmp, "abc", True, remote=None, state=state)
            self.assertEqual(later["remote"], "git@host:me/one.git")
            # working is not talking: only a prompt moves promptAt
            worked = zyt.write_session("claude-code", tmp, "abc", False, remote=None, state=state)
            self.assertEqual(worked["promptAt"], later["promptAt"])
            self.assertEqual(json.loads((state / "sessions" / "abc.json").read_text()), worked)
            # the note and the lock that serialises the hooks writing it, and no
            # temporary file left behind
            self.assertEqual(sorted(path.name for path in (state / "sessions").iterdir()), [".lock", "abc.json"])

    def test_an_event_that_arrives_late_does_not_move_the_note_back(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state"
            zyt.write_session("claude-code", "/now", "abc", True, remote="git@host:me/now.git", state=state, at=2000)
            # the older event waited on git and got the lock second; it is still
            # the older event, and says nothing about where the session is now
            late = zyt.write_session(
                "claude-code", "/then", "abc", True, remote="git@host:me/then.git", state=state, at=1000
            )
            self.assertEqual((late["at"], late["promptAt"]), (2000, 2000))
            self.assertEqual(late["cwd"], "/now")
            self.assertEqual(late["remote"], "git@host:me/now.git")

    def test_a_late_event_still_fills_in_what_the_note_does_not_say(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state"
            zyt.write_session("claude-code", "/now", "abc", False, remote=None, state=state, at=2000)
            late = zyt.write_session(
                "claude-code", "/then", "abc", True, remote="git@host:me/then.git", state=state, at=1000
            )
            self.assertEqual(late["remote"], "git@host:me/then.git")
            self.assertEqual(late["promptAt"], 1000)  # it was still a prompt

    def test_two_events_in_one_second_are_still_told_apart(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state"
            zyt.write_session("claude-code", "/now", "abc", True, remote="git@host:me/now.git", state=state, at=2000.8)
            # the same second, so `at` cannot separate them; the one that waited
            # on git happened earlier all the same
            late = zyt.write_session(
                "claude-code", "/then", "abc", True, remote="git@host:me/then.git", state=state, at=2000.2
            )
            self.assertEqual(late["at"], 2000)
            self.assertEqual(late["cwd"], "/now")
            self.assertEqual(late["remote"], "git@host:me/now.git")

    def test_the_note_names_the_terminal_pane_it_was_opened_in(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state"
            with mock.patch.dict(os.environ, {"ITERM_SESSION_ID": "w0t3p0:PANE-A"}):
                note = zyt.write_session("claude-code", tmp, "abc", True, remote=None, state=state)
                self.assertEqual(note["pane"], "PANE-A")
                self.assertEqual(zyt.write_context("claude-code", tmp, state, remote=None)["pane"], "PANE-A")
            # the pane a session was opened in does not change, so an event from
            # somewhere with nothing to say about panes does not unset it
            with mock.patch.dict(os.environ, {}, clear=True):
                later = zyt.write_session("claude-code", tmp, "abc", False, remote=None, state=state)
                self.assertEqual(later["pane"], "PANE-A")
                self.assertIsNone(zyt.write_context("claude-code", tmp, state, remote=None)["pane"])

    def test_a_terminal_that_says_nothing_about_panes_leaves_the_field_empty(self):
        with mock.patch.dict(os.environ, {}, clear=True):
            self.assertIsNone(zyt.terminal_pane())
        with mock.patch.dict(os.environ, {"ITERM_SESSION_ID": "", "TERM_SESSION_ID": "w0t0p0:PANE-B"}):
            self.assertEqual(zyt.terminal_pane(), "PANE-B")
        # no colon in it, and the whole value is the pane
        with mock.patch.dict(os.environ, {"ITERM_SESSION_ID": "PANE-C"}):
            self.assertEqual(zyt.terminal_pane(), "PANE-C")

    def test_the_lock_is_a_file_of_its_own_and_is_let_go_again(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "sessions" / zyt.SESSION_LOCK
            with zyt.locked(path):
                self.assertTrue(path.exists())
            with zyt.locked(path):  # a second hook is not kept out for ever
                pass

    def test_the_lock_outlives_the_notes_it_guards(self):
        with tempfile.TemporaryDirectory() as tmp:
            directory = Path(tmp) / "sessions"
            zyt.write_session("claude-code", tmp, "old", True, remote=None, state=Path(tmp))
            long_ago = time.time() - zyt.SESSION_TTL - 60
            for name in ("old.json", zyt.SESSION_LOCK):
                os.utime(directory / name, (long_ago, long_ago))
            # a lock is empty and keeps the date it was made, so its age says
            # nothing; unlinking it while a hook holds it would undo the point
            zyt.prune_sessions(directory, time.time())
            self.assertFalse((directory / "old.json").exists())
            self.assertTrue((directory / zyt.SESSION_LOCK).exists())

    def test_the_title_is_the_name_the_chat_gave_itself(self):
        with tempfile.TemporaryDirectory() as tmp:
            transcript = Path(tmp) / "session.jsonl"
            transcript.write_text(
                "\n".join(
                    json.dumps(entry)
                    for entry in (
                        {"type": "ai-title", "aiTitle": "An older name"},
                        {"type": "user", "message": {"content": "hello"}},
                        {"type": "ai-title", "aiTitle": "  The filer  chargeback\n numbers "},
                        {"type": "last-prompt", "lastPrompt": "and what about the rest"},
                    )
                )
                + "\n"
            )
            # the newest title wins, and it arrives as one line
            self.assertEqual(zyt.chat_title(str(transcript)), "The filer chargeback numbers")

    def test_a_name_typed_in_by_hand_outranks_the_one_the_tool_made_up(self):
        with tempfile.TemporaryDirectory() as tmp:
            transcript = Path(tmp) / "session.jsonl"
            transcript.write_text(
                "\n".join(
                    json.dumps(entry)
                    for entry in (
                        {"type": "custom-title", "customTitle": "massy-ux"},
                        {"type": "ai-title", "aiTitle": "Whatever it is about"},
                        {"type": "last-prompt", "lastPrompt": "and then"},
                    )
                )
                + "\n"
            )
            # the tool goes on titling a conversation that has been renamed, and
            # the name in the person's own list is still the one they typed
            self.assertEqual(zyt.chat_title(str(transcript)), "massy-ux")

    def test_a_line_that_was_half_written_is_passed_over(self):
        with tempfile.TemporaryDirectory() as tmp:
            transcript = Path(tmp) / "session.jsonl"
            transcript.write_text(
                json.dumps({"type": "ai-title", "aiTitle": "Whole"}) + "\n" + '{"type":"ai-title","aiTitle":"Half of'
            )
            self.assertEqual(zyt.chat_title(str(transcript)), "Whole")

    def test_a_transcript_with_no_title_yet_offers_the_last_prompt(self):
        with tempfile.TemporaryDirectory() as tmp:
            transcript = Path(tmp) / "session.jsonl"
            transcript.write_text(
                json.dumps({"type": "last-prompt", "lastPrompt": "why does it keep asking me"}) + "\n"
            )
            self.assertEqual(zyt.chat_title(str(transcript)), "why does it keep asking me")

    def test_a_title_longer_than_a_row_is_cut(self):
        self.assertEqual(zyt.one_line("x" * 200), "x" * (zyt.TITLE_MAX - 1) + "\u2026")
        self.assertEqual(zyt.one_line("  two   words "), "two words")

    def test_a_transcript_nobody_can_read_says_nothing(self):
        self.assertEqual(zyt.chat_title("/nowhere/session.jsonl"), "")
        self.assertEqual(zyt.chat_title(None), "")
        self.assertEqual(zyt.chat_title(""), "")

    def test_only_the_end_of_a_long_transcript_is_read(self):
        with tempfile.TemporaryDirectory() as tmp:
            transcript = Path(tmp) / "session.jsonl"
            older = json.dumps({"type": "ai-title", "aiTitle": "Out of reach"})
            newest = json.dumps({"type": "ai-title", "aiTitle": "Within reach"})
            transcript.write_text(older + "\n" + " " * 4096 + "\n" + newest + "\n")
            tail = zyt.TRANSCRIPT_TAIL
            zyt.TRANSCRIPT_TAIL = 200
            try:
                # the slice starts in the middle of a line, which json says is no
                # line, and the entry before it is out of reach rather than wrong
                self.assertEqual(zyt.chat_title(str(transcript)), "Within reach")
            finally:
                zyt.TRANSCRIPT_TAIL = tail

    def test_the_title_follows_the_prompt_and_is_kept_between_them(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state"
            first = zyt.write_session("claude-code", tmp, "abc", True, remote=None, state=state, title="A name")
            self.assertEqual(first["title"], "A name")
            # a tool event knows nothing about what the chat is called
            worked = zyt.write_session("claude-code", tmp, "abc", False, remote=None, state=state)
            self.assertEqual(worked["title"], "A name")
            # and an event that arrives late does not bring the old name back
            late = zyt.write_session("claude-code", tmp, "abc", True, remote=None, state=state, title="Older", at=1)
            self.assertEqual(late["title"], "A name")
            newer = zyt.write_session("claude-code", tmp, "abc", True, remote=None, state=state, title="A new name")
            self.assertEqual(newer["title"], "A new name")

    def test_a_prompt_behind_a_tool_event_still_brings_its_title(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state"
            zyt.write_session("claude-code", tmp, "abc", True, remote=None, state=state, title="A name", at=1000)
            # a tool event of the same session got the lock first
            zyt.write_session("claude-code", tmp, "abc", False, remote=None, state=state, at=2000)
            # and the prompt that waited on git is still the newest prompt there
            # is, which is the one this title belongs to
            late = zyt.write_session(
                "claude-code", tmp, "abc", True, remote=None, state=state, title="A newer name", at=1500
            )
            self.assertEqual((late["promptAt"], late["title"]), (1500, "A newer name"))

    def test_a_prompt_is_dated_to_the_microsecond_as_well(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state"
            note = zyt.write_session("claude-code", tmp, "abc", True, remote=None, state=state, at=1000.25)
            # the second is what everything is dated by; the moment is there so
            # that a prompt and an answer of the same second can be put in order
            self.assertEqual((note["promptAt"], note["promptOrder"]), (1000, 1000.25))
            worked = zyt.write_session("claude-code", tmp, "abc", False, remote=None, state=state, at=1001.5)
            self.assertEqual(worked["promptOrder"], 1000.25)
            later = zyt.write_session("claude-code", tmp, "abc", True, remote=None, state=state, at=1002.75)
            self.assertEqual(later["promptOrder"], 1002.75)

    def test_the_hook_keeps_the_fraction_of_the_second(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state"
            payload = {"hook_event_name": "UserPromptSubmit", "session_id": "abc", "cwd": tmp}
            stdin, stdout = zyt.sys.stdin, zyt.sys.stdout
            was = zyt.STATE
            zyt.STATE = state
            try:
                zyt.sys.stdin = io.StringIO(json.dumps(payload))
                zyt.sys.stdout = io.StringIO()
                with mock.patch.object(zyt.time, "time", return_value=1000.25):
                    zyt.cmd_hook(argparse.Namespace(tool="claude-code"))
            finally:
                zyt.sys.stdin, zyt.sys.stdout = stdin, stdout
                zyt.STATE = was
            note = json.loads((state / "sessions" / "abc.json").read_text())
            # the second is what the notes are dated by, and the moment is what
            # puts a prompt and an answer of that second in order. The fraction
            # has to survive the hook, which had rounded it off before it began.
            self.assertEqual((note["promptAt"], note["promptOrder"]), (1000, 1000.25))
            self.assertEqual(json.loads((state / "chat.json").read_text())["at"], 1000)

    def test_a_session_that_has_only_worked_is_no_chat(self):
        with tempfile.TemporaryDirectory() as tmp:
            note = zyt.write_session("claude-code", tmp, "abc", False, remote=None, state=Path(tmp) / "state")
            self.assertIsNone(note["promptAt"])

    def test_a_session_id_that_is_not_a_file_name_is_not_written(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state"
            for bad in (None, "", "../escape", "a/b", ".hidden", "x" * 200):
                self.assertIsNone(zyt.write_session("claude-code", tmp, bad, True, remote=None, state=state))
            self.assertFalse((state / "sessions").exists())

    def test_notes_of_sessions_long_over_are_pruned(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = Path(tmp) / "state"
            zyt.write_session("claude-code", tmp, "old", True, remote=None, state=state)
            stale = state / "sessions" / "old.json"
            long_ago = time.time() - zyt.SESSION_TTL - 60
            os.utime(stale, (long_ago, long_ago))
            zyt.write_session("claude-code", tmp, "new", True, remote=None, state=state)
            self.assertFalse(stale.exists())
            self.assertTrue((state / "sessions" / "new.json").exists())

    def test_the_hook_writes_one_note_per_session(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = zyt.STATE
            zyt.STATE = Path(tmp) / "state"
            stdin, stdout = zyt.sys.stdin, zyt.sys.stdout
            try:
                zyt.sys.stdout = io.StringIO()
                for session in ("a", "b"):
                    zyt.sys.stdin = io.StringIO(
                        json.dumps({"cwd": tmp, "hook_event_name": "UserPromptSubmit", "session_id": session})
                    )
                    zyt.main(["hook", "claude-code"])
                written = sorted(path.name for path in (zyt.STATE / "sessions").iterdir() if path.suffix == ".json")
                self.assertEqual(written, ["a.json", "b.json"])
                self.assertEqual(zyt.sys.stdout.getvalue(), "")
                # both notes of one prompt carry the same second, so the Spoon
                # can tell them apart from an older chat's note
                note = json.loads((zyt.STATE / "sessions" / "b.json").read_text())
                self.assertEqual(note["promptAt"], json.loads((zyt.STATE / "chat.json").read_text())["at"])
            finally:
                zyt.sys.stdin, zyt.sys.stdout = stdin, stdout
                zyt.STATE = state

    def test_the_hook_reads_the_cwd_from_stdin_and_prints_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = zyt.STATE
            zyt.STATE = Path(tmp) / "state"
            stdin, stdout = zyt.sys.stdin, zyt.sys.stdout
            zyt.sys.stdin = io.StringIO(json.dumps({"cwd": tmp, "hook_event_name": "UserPromptSubmit"}))
            zyt.sys.stdout = io.StringIO()
            try:
                code = zyt.main(["hook", "claude-code"])
                self.assertEqual(zyt.sys.stdout.getvalue(), "")
            finally:
                zyt.sys.stdin, zyt.sys.stdout = stdin, stdout
            self.assertEqual(code, 0)
            self.assertEqual(json.loads((zyt.STATE / "context.json").read_text())["cwd"], tmp)
            zyt.STATE = state


if __name__ == "__main__":
    unittest.main()
