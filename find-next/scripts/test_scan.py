#!/usr/bin/env python3
"""Unit tests for the find-next deterministic tracker scanner."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


# ``python -I`` does not put the script directory on sys.path, so import the
# scanner explicitly from its own directory.
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
if SCRIPT_DIR not in sys.path:
    sys.path.insert(0, SCRIPT_DIR)

import scan  # noqa: E402


def ticket_markdown(
    ticket_id,
    title,
    status="open",
    type_="task",
    blocked_by="—",
    assignee="—",
    triage=None,
    body="## Question\n\n做什么？\n",
):
    triage_line = f"Triage: {triage}\n" if triage is not None else ""
    return f"""# {ticket_id} · {title}

Status: {status}
Type: {type_}
Blocked-by: {blocked_by}
Assignee: {assignee}
{triage_line}
{body}"""


def map_markdown(title, destination, notes="", status_line=None):
    status = f"- 状态：{status_line}\n" if status_line else ""
    return f"""# Wayfinder 地图 · {title}

- Label: `wayfinder:map`
{status}
## Destination

{destination}

## Notes

{notes}
"""


class TrackerFixture:
    def __enter__(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.tracker = self.root / "tracker"
        (self.tracker / "tickets").mkdir(parents=True)
        return self

    def __exit__(self, *exc):
        self.tmp.cleanup()

    def ticket(self, ticket_id, slug="t", **kwargs):
        path = self.tracker / "tickets" / f"{ticket_id:02d}-{slug}.md"
        path.write_text(ticket_markdown(ticket_id, **kwargs), encoding="utf-8")
        return path

    def map(self, filename, **kwargs):
        path = self.tracker / filename
        path.write_text(map_markdown(**kwargs), encoding="utf-8")
        return path

    def build(self):
        return scan.build(self.tracker)


class ParseTicketTests(unittest.TestCase):
    def blocked(self, value):
        text = ticket_markdown(1, "t", blocked_by=value)
        ticket = scan.parse_ticket(text, "tickets/01-t.md")
        return ticket["blocked_by"], ticket["blocked_note"]

    def test_blocked_by_variants(self):
        cases = [
            ("—", [], None),
            ("48, 51", [48, 51], None),
            ("62（已关闭）", [62], "已关闭"),
            ("59, 61, 63（均已关闭）", [59, 61, 63], "均已关闭"),
            ("01（已关闭，可开工）", [1], "已关闭，可开工"),
            (
                "—（实际被「主人定 MiniMax key 接收方式并拿到 key」挡住，非票内依赖）",
                [],
                "实际被「主人定 MiniMax key 接收方式并拿到 key」挡住，非票内依赖",
            ),
        ]
        for value, ids, note in cases:
            with self.subTest(value=value):
                self.assertEqual(self.blocked(value), (ids, note))

    def test_status_and_type_are_normalized(self):
        text = ticket_markdown(
            5,
            "t",
            status="closed（out of scope，重新定向）",
            type_="task (HITL，用户出面)",
        )
        ticket = scan.parse_ticket(text, "tickets/05-t.md")
        self.assertEqual(ticket["status"], "closed")
        self.assertEqual(ticket["type"], "task")

    def test_assignee_variants(self):
        cases = [
            ("—", None),
            ("", None),
            ("claude（charting）", "claude（charting）"),
        ]
        for value, expected in cases:
            with self.subTest(value=value):
                text = ticket_markdown(1, "t", assignee=value)
                ticket = scan.parse_ticket(text, "tickets/01-t.md")
                self.assertEqual(ticket["assignee"], expected)

    def test_spec_body_detection_is_case_insensitive(self):
        for heading in ("Problem Statement", "USER STORIES"):
            with self.subTest(heading=heading):
                text = ticket_markdown(1, "t", body=f"## {heading}\n\n正文\n")
                ticket = scan.parse_ticket(text, "tickets/01-t.md")
                self.assertTrue(ticket["has_spec_body"])

    def test_parent_three_forms(self):
        cases = [
            (
                "SPEC.md「统一部署」章（wayfinder 票 47 定稿）。依据：SPEC D17/D28。",
                [47],
            ),
            ("票 30《SPEC：问题反馈与复现链路》（决策 SPEC D24–D27）。", [30]),
            (
                "依据：[票 59](59-渠道.md)、[票 61 修订](61-服务器.md) Resolution。",
                [59, 61],
            ),
        ]
        for parent_body, expected in cases:
            with self.subTest(parent_body=parent_body):
                text = ticket_markdown(
                    1, "t", body=f"## Parent\n\n{parent_body}\n\n## Question\n\nx\n"
                )
                ticket = scan.parse_ticket(text, "tickets/01-t.md")
                self.assertEqual(ticket["parents"], expected)

    def test_report_file_name_is_not_a_parent(self):
        parent = "票 37《v1.1 试用问题修复》；报告 `reports/dogfood-v1.1-20261029.md` 第 16 条。"
        text = ticket_markdown(1, "t", body=f"## Parent\n\n{parent}\n")
        ticket = scan.parse_ticket(text, "tickets/01-t.md")
        self.assertEqual(ticket["parents"], [37])


class MapAndGraphTests(unittest.TestCase):
    def test_map_mentions_ranges_and_ticket_links(self):
        with TrackerFixture() as fixture:
            fixture.map(
                "map.md",
                title="主线",
                destination="SPEC 定稿",
                notes="见 [票 01](tickets/01-a.md)、票 31-36；后续票 64–69。",
            )
            for ticket_id in [1, *range(31, 38), 64, 69]:
                fixture.ticket(ticket_id, slug="a", title=f"票 {ticket_id}")
            result = fixture.build()
            members = result["maps"][0]["members"]
            self.assertIn(1, members)
            for ticket_id in range(31, 37):
                self.assertIn(ticket_id, members)
            self.assertIn(64, members)
            self.assertIn(69, members)
            self.assertNotIn(37, members)
            self.assertEqual(result["maps"][0]["sections"], ["Destination", "Notes"])

    def test_explicit_and_mentioned_map_union(self):
        with TrackerFixture() as fixture:
            fixture.map("map-a.md", title="A", destination="SPEC 增补「A」章")
            fixture.map("map-b.md", title="B", destination="SPEC 增补「B」章", notes="提到票 02")
            fixture.ticket(1, title="一", body="地图：[A](../map-a.md)\n\n## Question\n\nx\n")
            fixture.ticket(2, title="二")
            result = fixture.build()
            by_id = {t["id"]: t for t in result["tickets"]}
            self.assertEqual(by_id[1]["maps_explicit"], ["map-a.md"])
            self.assertEqual(by_id[1]["maps_mentioned"], [])
            self.assertEqual(by_id[2]["maps_explicit"], [])
            self.assertEqual(by_id[2]["maps_mentioned"], ["map-b.md"])
            members = {m["file"]: m["members"] for m in result["maps"]}
            self.assertEqual(members["map-a.md"], [1])
            self.assertEqual(members["map-b.md"], [2])

    def test_downstream_transitive_and_cycle_safe(self):
        with TrackerFixture() as fixture:
            fixture.ticket(1, title="源头")
            fixture.ticket(2, title="二", blocked_by="1")
            fixture.ticket(3, title="三", blocked_by="2")
            fixture.ticket(4, title="四", blocked_by="3", status="closed")
            fixture.ticket(5, title="五", blocked_by="4")
            fixture.ticket(6, title="六", blocked_by="7")
            fixture.ticket(7, title="七", blocked_by="6")
            result = fixture.build()
            by_id = {t["id"]: t for t in result["tickets"]}
            self.assertEqual(by_id[1]["downstream_open"], 3)  # 2、3、5（4 已关闭）
            self.assertEqual(by_id[3]["downstream_open"], 1)  # 5
            self.assertEqual(by_id[6]["downstream_open"], 1)  # 7，防环且自身不计
            self.assertEqual(by_id[6]["open_blockers"], [7])

    def test_missing_blocker_is_open_and_warned(self):
        with TrackerFixture() as fixture:
            fixture.ticket(1, title="一", blocked_by="99")
            result = fixture.build()
            self.assertEqual(result["tickets"][0]["open_blockers"], [99])
            self.assertTrue(any("99" in warning for warning in result["warnings"]))

    def test_children_reverse_index(self):
        with TrackerFixture() as fixture:
            fixture.ticket(30, title="SPEC 问题反馈")
            fixture.ticket(
                31,
                title="子一",
                body="## Parent\n\n票 30《SPEC 问题反馈》。\n\n## Question\n\nx\n",
            )
            fixture.ticket(
                32,
                title="子二",
                body="## Parent\n\n[票 30](30-SPEC问题反馈.md)\n\n## Question\n\nx\n",
            )
            result = fixture.build()
            by_id = {t["id"]: t for t in result["tickets"]}
            self.assertEqual(by_id[30]["children"], [31, 32])
            self.assertEqual(by_id[31]["children"], [])


class ShelvedTests(unittest.TestCase):
    def _assert_ticket(self, title, body, expected):
        text = ticket_markdown(1, title, body=body)
        ticket = scan.parse_ticket(text, "tickets/01-t.md")
        self.assertEqual(ticket["shelved"], expected)

    def test_ticket_shelved_only_in_title_or_header(self):
        self._assert_ticket("裁剪调用清单（搁置）", "", True)
        self._assert_ticket("裁剪调用清单", "Triage: wontfix（搁置暂缓）\n", True)
        self._assert_ticket(
            "裁剪调用清单",
            "## 调查结论与裁定（2026-10-31，搁置）\n\n正文提到搁置。\n",
            False,
        )

    def test_map_shelved_only_in_title_or_status_line(self):
        self.assertTrue(
            scan.parse_map(map_markdown("单份成本（已搁置）", "SPEC 章"), "map-x.md")["shelved"]
        )
        self.assertTrue(
            scan.parse_map(
                map_markdown("单份成本", "SPEC 章", status_line="**搁置**（待启封）"),
                "map-x.md",
            )["shelved"]
        )
        self.assertFalse(
            scan.parse_map(
                map_markdown("单份成本", "SPEC 章", notes="正文说搁置"), "map-x.md"
            )["shelved"]
        )


class CandidateTests(unittest.TestCase):
    def test_to_tickets_positive_and_negative(self):
        with TrackerFixture() as fixture:
            # 正：closed task、标题含 SPEC、无 children
            fixture.ticket(10, title="SPEC 增补「渠道」章", status="closed")
            # 反：有 children（已拆票）
            fixture.ticket(20, title="SPEC 增补「反馈」章", status="closed")
            fixture.ticket(
                21,
                title="执行票",
                body="## Parent\n\n票 20 定稿\n\n## Question\n\nx\n",
            )
            # 正：spec 正文 + ready-for-agent
            fixture.ticket(
                30,
                title="规格票",
                triage="ready-for-agent",
                body="## Problem Statement\n\nx\n",
            )
            # 反：spec 正文但未 ready
            fixture.ticket(31, title="未分诊规格票", body="## User Stories\n\nx\n")
            # 反：搁置
            fixture.ticket(
                32,
                title="搁置规格票",
                triage="ready-for-agent",
                body="## Problem Statement\n\nx\n",
            )
            result = fixture.build()
            ids = [c["id"] for c in result["candidates"]["to_tickets"]]
            self.assertEqual(ids, [10, 30])

    def test_to_spec_positive_and_negative(self):
        with TrackerFixture() as fixture:
            # 正：前沿已空，无 SPEC 收口票
            fixture.map("map-a.md", title="A", destination="SPEC 增补「A」章并定稿")
            fixture.ticket(
                1,
                title="决策一",
                status="closed",
                body="地图：[A](../map-a.md)\n\n## Question\n\nx\n",
            )
            fixture.ticket(2, title="决策二", status="closed")
            # 反：地图搁置
            fixture.map(
                "map-b.md", title="B", destination="SPEC 增补「B」章", status_line="**搁置**"
            )
            fixture.ticket(3, title="决策三", status="closed")
            # 反：唯一 open 成员不是 SPEC 收口票
            fixture.map("map-c.md", title="C", destination="SPEC 增补「C」章")
            fixture.ticket(
                4,
                title="待决策",
                body="地图：[C](../map-c.md)\n\n## Question\n\nx\n",
            )
            # 反：已有带 children 的 SPEC 收口票（已 to-tickets）
            fixture.map("map-d.md", title="D", destination="SPEC 增补「D」章")
            fixture.ticket(
                5,
                title="SPEC 增补「D」章",
                status="closed",
                body="地图：[D](../map-d.md)\n\n## Question\n\nx\n",
            )
            fixture.ticket(
                6,
                title="执行票",
                body="## Parent\n\n票 5 定稿\n\n## Question\n\nx\n",
            )
            # 正：唯一 open 成员是 SPEC 收口票且阻塞已关闭
            fixture.map("map-e.md", title="E", destination="SPEC 增补「E」章")
            fixture.ticket(7, title="决策七", status="closed")
            fixture.ticket(
                8,
                title="SPEC 增补「E」章",
                blocked_by="7",
                body="地图：[E](../map-e.md)\n\n## Question\n\nx\n",
            )
            result = fixture.build()
            maps = [c["map"] for c in result["candidates"]["to_spec"]]
            self.assertEqual(maps, ["map-a.md", "map-e.md"])
            reasons = {c["map"]: c["reason"] for c in result["candidates"]["to_spec"]}
            self.assertIn("no open members", reasons["map-a.md"])
            self.assertIn("one open SPEC member", reasons["map-e.md"])

    def test_frontier_positive_negative_and_ordering(self):
        with TrackerFixture() as fixture:
            fixture.ticket(1, title="已关决策", status="closed")
            fixture.ticket(2, title="开放决策", blocked_by="1")
            fixture.ticket(3, title="被挡决策", blocked_by="2")
            fixture.ticket(4, title="已认领", blocked_by="1", assignee="codex")
            fixture.ticket(5, title="claimed", status="claimed", blocked_by="1")
            fixture.ticket(6, title="搁置票")
            fixture.ticket(7, title="无下游", blocked_by="1")
            result = fixture.build()
            frontier = result["candidates"]["frontier"]
            self.assertEqual([c["id"] for c in frontier], [2, 7])
            self.assertEqual(frontier[0]["downstream_open"], 1)
            self.assertEqual(frontier[0]["maps"], [])

    def test_map_frontier_field(self):
        with TrackerFixture() as fixture:
            fixture.map(
                "map.md",
                title="主线",
                destination="SPEC 章",
                notes="成员：票 1、票 2、票 3。",
            )
            fixture.ticket(1, title="已关", status="closed")
            fixture.ticket(2, title="可开工", blocked_by="1")
            fixture.ticket(3, title="被挡", blocked_by="2")
            result = fixture.build()
            self.assertEqual(result["maps"][0]["frontier"], [2])
            self.assertEqual(result["maps"][0]["open_members"], [2, 3])


class CliTests(unittest.TestCase):
    def run_scan(self, *args):
        script = os.path.join(SCRIPT_DIR, "scan.py")
        return subprocess.run(
            [sys.executable, "-I", script, *args],
            capture_output=True,
            text=True,
        )

    def test_nonexistent_tracker_exits_2(self):
        proc = self.run_scan("--tracker", os.path.join(os.sep, "nonexistent"))
        self.assertEqual(proc.returncode, 2)
        self.assertIn("does not exist", proc.stderr)

    def test_missing_argument_exits_2(self):
        proc = self.run_scan()
        self.assertEqual(proc.returncode, 2)
        self.assertTrue(proc.stderr)

    def test_valid_run_outputs_json(self):
        with TrackerFixture() as fixture:
            fixture.ticket(1, title="一")
            proc = self.run_scan("--tracker", str(fixture.tracker))
            self.assertEqual(proc.returncode, 0, proc.stderr)
            data = json.loads(proc.stdout)
            self.assertEqual(len(data["tickets"]), 1)
            self.assertEqual(data["warnings"], [])
            self.assertTrue(Path(data["tracker"]).is_absolute())


if __name__ == "__main__":
    unittest.main()
