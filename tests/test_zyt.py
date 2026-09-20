"""The report's arithmetic, and the note the hook leaves behind."""

import datetime as dt
import importlib.machinery
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path

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
        self.assertEqual(zyt.summarise([]), {"start": None, "end": None, "work": 0, "private": 0, "break": 0})


class Capacity(unittest.TestCase):
    def test_blocks_and_breaks_inside_the_window(self):
        self.assertEqual(zyt.capacity(REPORT), 12 * 60)  # 5h + 30' + 5h + 30' + 2h
        self.assertEqual(zyt.capacity({**REPORT, "latest": "12:00"}), 5 * 60)  # 5h window, one block
        self.assertEqual(zyt.capacity({**REPORT, "maxBlockMinutes": 60, "breakMinutes": 60}), 7 * 60)


class Layout(unittest.TestCase):
    def test_a_day_that_fits_keeps_its_own_start(self):
        summary = {"start": at("2026-09-14", "08:02")}
        blocks = zyt.layout(zyt.anchor(summary, REPORT), 7 * 60 + 55, REPORT)
        self.assertEqual(blocks, [[8 * 60, 13 * 60], [13 * 60 + 30, 16 * 60 + 25]])

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


def week(**hours):
    """A week from Monday 2026-09-14 with the given work minutes per weekday name."""
    monday = dt.date(2026, 9, 14)
    days = {}
    for i, name in enumerate(["mon", "tue", "wed", "thu", "fri", "sat", "sun"]):
        day = monday + dt.timedelta(days=i)
        mins = hours.get(name, 0)
        start = at(day.isoformat(), "09:00") if mins else None
        days[day] = {"start": start, "end": None, "work": mins * 60, "private": 0, "break": 0}
    return days


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
            self.assertFalse((state / "context.json.tmp").exists())

    def test_the_hook_reads_the_cwd_from_stdin_and_prints_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
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


if __name__ == "__main__":
    unittest.main()
