"""The report's arithmetic, and the note the hook leaves behind."""

import datetime as dt
import importlib.machinery
import importlib.util
import io
import json
import os
import sys
import tempfile
import time
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
