#!/usr/bin/env python3
"""Deterministic scanner for the local markdown wayfinder tracker.

Usage:
    python3 -I scan.py --tracker <tracker directory>

The script reads ``map*.md`` and ``tickets/NN-*.md`` files and prints a JSON
summary (stdout) for downstream model judgement.  It is deterministic, uses
only the Python standard library and never touches the network.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import deque
from pathlib import Path


TICKET_NAME_RE = re.compile(r"^(\d{1,4})-.+\.md$")
TICKET_TITLE_RE = re.compile(r"^#\s*(\d{1,4})\s*[·•:：\-–—]\s*(.+?)\s*$")
HEADING2_RE = re.compile(r"^##\s+(.+?)\s*$")
HEADER_FIELD_RE = re.compile(r"^(Status|Type|Blocked-by|Assignee|Triage)\s*:\s*(.*)$")
MAP_LINE_RE = re.compile(r"^\s*-?\s*地图：\s*(.*)$")
MD_LINK_RE = re.compile(r"\[[^\]]+\]\(([^()\s]+)\)")
SPEC_SECTION_RE = re.compile(r"^##\s*(Problem Statement|User Stories)\s*$", re.IGNORECASE)

# 「票 NN」 / 「票 NN–MM」（also accepts hyphen / em dash）
TICKET_RANGE_RE = re.compile(r"票\s*(\d{1,4})\s*[–—-]\s*(\d{1,4})(?!\d)")
TICKET_SINGLE_RE = re.compile(r"票\s*(\d{1,4})(?!\d)")
TICKET_LIST_RE = re.compile(r"票\s*(\d{1,4}(?:\s*[、,，]\s*\d{1,4})+)(?!\d)")

# A bare ticket-file reference such as ``59-渠道清单….md``.  The lookbehind
# rejects paths (``reports/...``) and names like ``dogfood-v1.1-20261029.md``;
# the negative lookahead rejects ids followed by another digit after the dash
# (``1-20261029.md`` is a date file, not ticket 1).
TICKET_FILE_RE = re.compile(r"(?<![\w./\-])(\d{1,4})-(?!\d)[^\s\])]*\.md")

DESTINATION_LIMIT = 600
STATUS_OPEN = "open"
STATUS_CLOSED = "closed"


def _first_token(value: str) -> str:
    """Normalize header values such as ``closed（out of scope）`` -> ``closed``."""
    return re.split(r"[（(\[，,;；]", value.strip(), maxsplit=1)[0].strip()


def _clean_assignee(value: str) -> str | None:
    value = value.strip()
    if value in {"", "—", "―", "–", "-", "无", "none"}:
        return None
    return value


def _split_lines(text: str) -> list[str]:
    return text.splitlines()


def _header_lines(lines: list[str]) -> list[str]:
    """Lines between the title and the first ``## `` heading."""
    header: list[str] = []
    for line in lines[1:]:
        if line.startswith("## "):
            break
        header.append(line)
    return header


def _parse_blocked_by(value: str) -> tuple[list[int], str | None]:
    """Parse the ``Blocked-by`` header.

    Ticket ids are the numbers outside any parenthesis; the first parenthesised
    remark is preserved verbatim in ``blocked_note``.
    """
    value = value.strip()
    note: str | None = None
    without_parens = value
    for opener, closer in (("（", "）"), ("(", ")")):
        while True:
            start = without_parens.find(opener)
            if start < 0:
                break
            end = without_parens.find(closer, start + 1)
            if end < 0:
                end = len(without_parens)
            inner = without_parens[start + 1 : end]
            if note is None:
                note = inner
            without_parens = without_parens[:start] + without_parens[end + 1 :]
    ids: list[int] = []
    for match in re.findall(r"\d+", without_parens):
        ticket_id = int(match)
        if ticket_id not in ids:
            ids.append(ticket_id)
    return ids, note


def _section_body(lines: list[str], wanted: str) -> list[str]:
    """Return the raw body lines of the first ``## <wanted>`` section."""
    body: list[str] = []
    inside = False
    for line in lines:
        heading = HEADING2_RE.match(line)
        if heading:
            if inside:
                break
            inside = heading.group(1).strip().lower() == wanted.lower()
            continue
        if inside:
            body.append(line)
    return body


def parse_ticket(text: str, filename: str) -> dict:
    """Parse one ticket file into the public ticket record."""
    name = Path(filename).name
    id_match = TICKET_NAME_RE.match(name)
    if not id_match:
        raise ValueError(f"not a ticket filename: {filename}")
    ticket_id = int(id_match.group(1))

    lines = _split_lines(text)
    title = ""
    title_match = TICKET_TITLE_RE.match(lines[0]) if lines else None
    if title_match:
        title = title_match.group(2).strip()
    else:
        title = re.sub(r"^#\s*", "", lines[0]).strip() if lines else ""

    header = _header_lines(lines)
    fields: dict[str, str] = {}
    for line in header:
        field = HEADER_FIELD_RE.match(line.strip())
        if field:
            fields.setdefault(field.group(1), field.group(2).strip())

    blocked_by, blocked_note = _parse_blocked_by(fields.get("Blocked-by", "—"))

    # Explicit map membership: a line starting with ``地图：`` linking a map.
    maps_explicit: list[str] = []
    for line in lines:
        map_line = MAP_LINE_RE.match(line)
        if not map_line:
            continue
        for target in MD_LINK_RE.findall(map_line.group(1)):
            base = Path(target).name
            if base.lower().endswith(".md") and base not in maps_explicit:
                maps_explicit.append(base)

    # Parents: mentions inside the ``## Parent`` section only.
    parent_body = "\n".join(_section_body(lines, "Parent"))
    parents: set[int] = set()
    for found in TICKET_SINGLE_RE.findall(parent_body):
        parents.add(int(found))
    for found in TICKET_LIST_RE.findall(parent_body):
        parents.update(int(n) for n in re.findall(r"\d+", found))
    for found in TICKET_FILE_RE.findall(parent_body):
        parents.add(int(found))

    has_spec_body = any(SPEC_SECTION_RE.match(line) for line in lines)

    header_text = "\n".join([lines[0] if lines else "", *header])
    shelved = "搁置" in title or "搁置" in header_text or re.search(r"(?m)^Status:\s*shelved\b", header_text) is not None

    return {
        "id": ticket_id,
        "file": f"tickets/{name}",
        "title": title,
        "status": _first_token(fields.get("Status", "")) or "open",
        "type": _first_token(fields.get("Type", "")) or "task",
        "assignee": _clean_assignee(fields.get("Assignee", "")),
        "triage": fields.get("Triage") or None,
        "blocked_by": blocked_by,
        "blocked_note": blocked_note,
        "maps_explicit": maps_explicit,
        "maps_mentioned": [],
        "parents": sorted(parents),
        "has_spec_body": has_spec_body,
        "shelved": shelved,
    }


def parse_map(text: str, filename: str) -> dict:
    """Parse one map file.

    ``mentioned_ids`` is an internal field consumed (and removed) by
    :func:`build` when it distributes map mentions onto tickets.
    """
    name = Path(filename).name
    lines = _split_lines(text)
    title = lines[0].lstrip("#").strip() if lines else ""

    sections: list[str] = []
    for line in lines:
        heading = HEADING2_RE.match(line)
        if heading:
            sections.append(heading.group(1).strip())

    destination_lines = _section_body(lines, "Destination")
    while destination_lines and not destination_lines[0].strip():
        destination_lines.pop(0)
    while destination_lines and not destination_lines[-1].strip():
        destination_lines.pop()
    destination = "\n".join(destination_lines)[:DESTINATION_LIMIT]

    shelved = "搁置" in title or any(
        "搁置" in line and "状态：" in line for line in lines
    )

    # Tickets mentioned by this map: ticket-file links plus 「票 NN」 and
    # 「票 NN–MM」 text mentions (ranges expanded).
    mentioned: set[int] = set()
    for target in MD_LINK_RE.findall(text):
        base = Path(target).name
        link_match = TICKET_NAME_RE.match(base)
        if link_match:
            mentioned.add(int(link_match.group(1)))
    consumed_ranges: list[tuple[int, int]] = []
    for match in TICKET_RANGE_RE.finditer(text):
        start, end = int(match.group(1)), int(match.group(2))
        consumed_ranges.append((match.start(), match.end()))
        if start <= end and end - start <= 1000:
            mentioned.update(range(start, end + 1))
    for match in TICKET_SINGLE_RE.finditer(text):
        if any(start <= match.start() < end for start, end in consumed_ranges):
            continue
        mentioned.add(int(match.group(1)))

    return {
        "file": name,
        "title": title,
        "shelved": shelved,
        "destination": destination,
        "destination_mentions_to_tickets": "to-tickets" in destination.lower(),
        "sections": sections,
        "mentioned_ids": sorted(mentioned),
    }


def _is_not_closed(ticket: dict) -> bool:
    return ticket["status"] != STATUS_CLOSED


def _downstream_open(ticket_id: int, tickets: dict[int, dict]) -> int:
    """Count not-closed tickets transitively blocked by ``ticket_id``."""
    reverse: dict[int, set[int]] = {}
    for child_id, ticket in tickets.items():
        for blocker in ticket["blocked_by"]:
            if blocker in tickets:
                reverse.setdefault(blocker, set()).add(child_id)
    seen = {ticket_id}
    queue = deque([ticket_id])
    count = 0
    while queue:
        current = queue.popleft()
        for child in sorted(reverse.get(current, ())):
            if child in seen:
                continue
            seen.add(child)
            if _is_not_closed(tickets[child]):
                count += 1
            queue.append(child)
    return count


def _satisfies_to_tickets(ticket: dict) -> bool:
    spec_body_rule = ticket["has_spec_body"] and ticket["triage"] == "ready-for-agent"
    closing_rule = (
        ticket["status"] == STATUS_CLOSED
        and ticket["type"] == "task"
        and "SPEC" in ticket["title"].upper()
    )
    return (spec_body_rule or closing_rule) and not ticket["children"] and not ticket["shelved"]


def _to_tickets_reason(ticket: dict) -> str:
    if ticket["has_spec_body"] and ticket["triage"] == "ready-for-agent":
        return "has spec body, ready-for-agent, no children"
    return "closed task, title has SPEC, no children"


def build(tracker_dir: str | Path) -> dict:
    """Scan ``tracker_dir`` and return the full result document."""
    tracker = Path(tracker_dir)
    warnings: list[str] = []

    tickets: dict[int, dict] = {}
    tickets_dir = tracker / "tickets"
    if tickets_dir.is_dir():
        for path in sorted(tickets_dir.iterdir(), key=lambda p: p.name):
            match = TICKET_NAME_RE.match(path.name)
            if not match or not path.is_file():
                continue
            ticket = parse_ticket(path.read_text(encoding="utf-8"), path.name)
            if ticket["id"] in tickets:
                warnings.append(f"duplicate ticket id {ticket['id']}")
            tickets[ticket["id"]] = ticket

    maps: dict[str, dict] = {}
    for path in sorted(tracker.glob("map*.md"), key=lambda p: p.name):
        if not path.is_file():
            continue
        map_record = parse_map(path.read_text(encoding="utf-8"), path.name)
        maps[map_record["file"]] = map_record

    # Maps mentioned by each map file -> per-ticket mentions.
    mentioned_by_file: dict[str, list[int]] = {}
    for map_record in maps.values():
        mentioned_by_file[map_record["file"]] = map_record.pop("mentioned_ids")
    for map_file, mentioned in mentioned_by_file.items():
        for ticket_id in mentioned:
            ticket = tickets.get(ticket_id)
            if ticket is not None and map_file not in ticket["maps_mentioned"]:
                ticket["maps_mentioned"].append(map_file)

    # Blocked-by bookkeeping.
    for ticket_id, ticket in sorted(tickets.items()):
        open_blockers: list[int] = []
        for blocker in ticket["blocked_by"]:
            blocker_ticket = tickets.get(blocker)
            if blocker_ticket is None:
                open_blockers.append(blocker)
                warnings.append(
                    f"ticket {ticket_id} is blocked by missing ticket {blocker}"
                )
            elif _is_not_closed(blocker_ticket):
                open_blockers.append(blocker)
        ticket["open_blockers"] = sorted(set(open_blockers))

    # Parent reverse index and transitive downstream counts.
    for ticket_id, ticket in tickets.items():
        ticket["children"] = []
    for ticket_id, ticket in sorted(tickets.items()):
        for parent in ticket["parents"]:
            parent_ticket = tickets.get(parent)
            if parent_ticket is not None and ticket_id not in parent_ticket["children"]:
                parent_ticket["children"].append(ticket_id)
    for ticket in tickets.values():
        ticket["children"].sort()
        ticket["blocked_by"].sort()
        ticket["maps_explicit"].sort()
        ticket["maps_mentioned"].sort()
        ticket["downstream_open"] = _downstream_open(ticket["id"], tickets)

    # Map membership / frontier.
    map_output: list[dict] = []
    for map_file in sorted(maps):
        map_record = maps[map_file]
        members = sorted(
            ticket_id
            for ticket_id, ticket in tickets.items()
            if map_file in ticket["maps_explicit"] + ticket["maps_mentioned"]
        )
        open_members = [m for m in members if _is_not_closed(tickets[m])]
        frontier = [
            m
            for m in members
            if tickets[m]["status"] == STATUS_OPEN
            and not tickets[m]["open_blockers"]
            and tickets[m]["assignee"] is None
            and not tickets[m]["shelved"]
        ]
        map_record["members"] = members
        map_record["open_members"] = open_members
        map_record["frontier"] = frontier
        map_output.append(map_record)

    # Coarse candidates (over-inclusive on purpose; the model prunes later).
    to_tickets = [
        {"id": ticket_id, "reason": _to_tickets_reason(ticket)}
        for ticket_id, ticket in sorted(tickets.items())
        if _satisfies_to_tickets(ticket)
    ]

    to_spec: list[dict] = []
    for map_record in map_output:
        if map_record["shelved"]:
            continue
        destination = map_record["destination"]
        if "SPEC" not in destination and "章" not in destination:
            continue
        open_members = map_record["open_members"]
        if not open_members:
            member_state = "no open members"
        elif len(open_members) == 1:
            only = tickets[open_members[0]]
            if "SPEC" not in only["title"].upper() or only["open_blockers"]:
                continue
            member_state = "one open SPEC member with no open blockers"
        else:
            continue
        closing = [
            m
            for m in map_record["members"]
            if "SPEC" in tickets[m]["title"].upper()
        ]
        if any(_satisfies_to_tickets(tickets[m]) or tickets[m]["children"] for m in closing):
            continue
        to_spec.append(
            {
                "map": map_record["file"],
                "reason": f"destination mentions SPEC or chapter, {member_state}",
                "open_members": open_members,
            }
        )

    frontier_candidates = [
        {
            "id": ticket_id,
            "downstream_open": ticket["downstream_open"],
            "maps": ticket["maps_explicit"] + ticket["maps_mentioned"],
        }
        for ticket_id, ticket in tickets.items()
        if ticket["status"] == STATUS_OPEN
        and not ticket["open_blockers"]
        and ticket["assignee"] is None
        and not ticket["shelved"]
    ]
    for candidate in frontier_candidates:
        candidate["maps"] = sorted(set(candidate["maps"]))
    frontier_candidates.sort(key=lambda c: (-c["downstream_open"], c["id"]))

    return {
        "tracker": str(tracker.resolve()),
        "tickets": [tickets[ticket_id] for ticket_id in sorted(tickets)],
        "maps": map_output,
        "candidates": {
            "to_tickets": to_tickets,
            "to_spec": to_spec,
            "frontier": frontier_candidates,
        },
        "warnings": sorted(set(warnings)),
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tracker", required=True, help="tracker directory to scan")
    args = parser.parse_args(argv)

    tracker = Path(args.tracker)
    if not tracker.is_dir():
        print(f"scan.py: tracker directory does not exist: {tracker}", file=sys.stderr)
        return 2

    result = build(tracker)
    print(json.dumps(result, ensure_ascii=False, indent=1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
