#!/usr/bin/env python3
"""Advisory completeness checks for untrusted pull-request descriptions."""

import argparse
import json
import os
import re
import sys
from pathlib import Path


SHA_RE = re.compile(r"(?<![0-9a-f])[0-9a-f]{40}(?![0-9a-f])", re.IGNORECASE)
ISSUE_RE = re.compile(
    r"(?:https?://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/issues/\d+|"
    r"\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?|related)\s+#\d+)",
    re.IGNORECASE,
)
TRUSTED_ASSOCIATIONS = {"OWNER", "MEMBER", "COLLABORATOR"}
STATUS_VALUES = {"verified", "not tested", "blocked", "weak", "unknown", "failed"}
PLACEHOLDER_RE = re.compile(
    r"^(?:\(?\s*(?:write\s+)?(?:none|n/?a|todo|tbd|exact head sha[^)]*|os and platform[^)]*|"
    r"criterion[^)]*from the issue|technical report)\s*\)?|[-—–]?\s*|"
    r"<[^>]+>)$",
    re.IGNORECASE,
)


class InputError(Exception):
    """Raised when an input cannot be safely interpreted."""


class ArgumentParser(argparse.ArgumentParser):
    def error(self, message):
        raise InputError("invalid command-line arguments")


def _lines(body):
    return body.replace("\r\n", "\n").replace("\r", "\n").splitlines()


def _evidence_text(body, *, preserve_responsibility=False):
    lines = []
    fence = None
    comment = None
    inline_code = re.compile(r"(?<!`)(`+)(?!`).*?(?<!`)\1(?!`)")
    for line in _lines(body):
        if fence:
            closing = re.fullmatch(r"\s*(`+|~+)\s*", line)
            if closing and closing.group(1)[0] == fence[0] and len(closing.group(1)) >= len(fence):
                fence = None
            lines.append("")
            continue
        opening = re.match(r"^\s*(`{3,}|~{3,})(.*)$", line)
        if comment is None and opening and not (opening.group(1)[0] == "`" and "`" in opening.group(2)):
            fence = opening.group(1)
            lines.append("")
            continue
        visible = []
        offset = 0
        while offset < len(line):
            if comment is not None:
                end = line.find("-->", offset)
                if end < 0:
                    comment.append(line[offset:] + "\n")
                    break
                comment.append(line[offset : end + 3])
                marker = "".join(comment)
                if preserve_responsibility and re.fullmatch(r"<!--\s*contributor-responsibility\s*-->", marker, re.IGNORECASE):
                    visible.append(marker)
                comment = None
                offset = end + 3
                continue
            code = inline_code.search(line, offset)
            start = line.find("<!--", offset)
            if code and (start < 0 or code.start() < start):
                visible.append(line[offset : code.end()])
                offset = code.end()
            elif start < 0:
                visible.append(line[offset:])
                break
            else:
                visible.append(line[offset:start])
                comment = ["<!--"]
                offset = start + 4
        lines.append("".join(visible))
    return "\n".join(lines)


def _clean(value):
    value = re.sub(r"[`*_]", "", value).strip()
    value = re.sub(r"\s+", " ", value)
    return value


def _substantive(value, *, allow_none=False):
    value = _clean(value)
    if not value:
        return False
    if allow_none and re.fullmatch(r"(?:none|n/?a)(?:\s*[-—:]\s*[^\n]+)?", value, re.IGNORECASE):
        return True
    if PLACEHOLDER_RE.fullmatch(value):
        return False
    if re.fullmatch(r"(?:https?://\S+|\[[^]]+\]\(https?://[^)]+\))", value, re.IGNORECASE):
        return False
    return not bool(re.fullmatch(r"(?:todo|tbd|n/?a|none)", value, re.IGNORECASE))


def _finding(code, message, **extra):
    item = {"code": code, "message": message, "severity": "advisory"}
    item.update(extra)
    return item


def _label_pattern(labels):
    return re.compile(
        r"^\s*(?:[-*]\s*)?(?:\*\*)?\s*(?:"
        + "|".join(re.escape(label) for label in labels)
        + r")\s*(?:\*\*)?\s*(?::\s*(.*))?$",
        re.IGNORECASE,
    )


def _field_line(body, labels):
    pattern = _label_pattern(labels)
    for line in _lines(body):
        match = pattern.match(line)
        if match and match.group(1) is not None:
            return match.group(1).strip()
    return None


def _section_text(body, labels):
    lines = _lines(body)
    label_pattern = _label_pattern(labels)
    heading_pattern = re.compile(r"^\s{0,3}(#{1,6})\s+(.+?)\s*#*\s*$")
    next_field = re.compile(
        r"^\s*(?:[-*]\s*)?(?:\*\*)?\s*[A-Za-z][A-Za-z /_-]{2,70}\s*(?:\*\*)?\s*:\s*",
        re.IGNORECASE,
    )
    sections = []
    for index, line in enumerate(lines):
        heading = heading_pattern.match(line)
        match = label_pattern.match(heading.group(2) if heading else line)
        if not match:
            continue
        values = [match.group(1) or ""]
        for following in lines[index + 1 :]:
            next_heading = heading_pattern.match(following)
            if next_heading and (not heading or len(next_heading.group(1)) <= len(heading.group(1))):
                break
            if not heading and next_field.match(following):
                break
            if following.strip() and not following.lstrip().startswith("<"):
                values.append(following.strip())
        sections.append("\n".join(values).strip())
    return "\n".join(sections).strip() or None


def _has_issue_or_exemption(body, *, association=None, author_type=None):
    if ISSUE_RE.search(body):
        return True
    trusted = (isinstance(association, str) and association.upper() in TRUSTED_ASSOCIATIONS) or (
        isinstance(author_type, str) and author_type.lower() == "bot"
    )
    if not trusted:
        return False
    lowered = body.lower()
    if re.search(
        r"\bn/?a\b[^\n]{0,120}\b(?:maintainer|repository[- ]maintenance|automated)",
        lowered,
    ) or re.search(r"\b(?:maintainer|automated repository[- ]maintenance)\s+exemption\b", lowered):
        return True
    lines = _lines(body)
    for index, line in enumerate(lines):
        if not re.search(r"linked issue|issue reference|tracking issue", line, re.IGNORECASE):
            continue
        for following in lines[index + 1 : index + 3]:
            if following.strip() and re.fullmatch(r"\s*(?:n/?a|none)\s*", following, re.IGNORECASE):
                return True
    return False


def _has_risk_and_rationale(body):
    candidates = []
    lines = _lines(body)
    for index, line in enumerate(lines):
        from_scope_heading = bool(re.match(r"^\s*#{1,6}\s+scope and risk\b", line, re.IGNORECASE))
        if from_scope_heading:
            following = []
            for candidate in lines[index + 1 :]:
                if re.match(r"^\s*#{1,6}\s+", candidate):
                    break
                if candidate.strip():
                    following.append(candidate.strip())
            line = " ".join(following)
        if not from_scope_heading and not re.search(r"\brisk\b|\bscope and risk\b", line, re.IGNORECASE):
            continue
        tiers = re.findall(r"\bL[0-3]\b", line, re.IGNORECASE)
        if tiers:
            candidates.append((line, tiers))
    if not candidates or len({tier.upper() for _, tiers in candidates for tier in tiers}) != 1:
        return False
    line, _ = max(candidates, key=lambda candidate: len(candidate[0]))
    tier_match = re.search(r"\bL[0-3]\b", line, re.IGNORECASE)
    trailing = line[tier_match.end() :].strip(" -*—–:;") if tier_match else ""
    rationale = _field_line(body, ("why this level", "risk rationale", "rationale"))
    if rationale is not None:
        return _substantive(rationale)
    return _substantive(trailing)


def _table_rows(body):
    lines = _lines(body)
    for index, line in enumerate(lines):
        if "|" not in line or not re.search(r"criterion|acceptance", line, re.IGNORECASE):
            continue
        header = [cell.strip().lower() for cell in line.strip().strip("|").split("|")]
        if not any("status" in cell for cell in header) or not any(
            "evidence" in cell or "test" in cell or "artifact" in cell for cell in header
        ):
            continue
        status_index = next(i for i, cell in enumerate(header) if "status" in cell)
        evidence_index = next(
            i for i, cell in enumerate(header) if "evidence" in cell or "test" in cell or "artifact" in cell
        )
        rows = []
        for candidate in lines[index + 1 :]:
            if "|" not in candidate:
                if candidate.strip():
                    break
                continue
            cells = [cell.strip() for cell in candidate.strip().strip("|").split("|")]
            if cells and re.fullmatch(r":?-+:?", cells[0].replace(" ", "")):
                continue
            rows.append((cells, status_index, evidence_index))
        yield rows


def _has_criteria_evidence(body):
    found_table = False
    found_valid = False
    for rows in _table_rows(body):
        found_table = True
        for cells, status_index, evidence_index in rows:
            if not any(_clean(cell) for cell in cells):
                return False
            if len(cells) <= max(status_index, evidence_index):
                return False
            criterion = cells[0]
            status = _clean(cells[status_index]).lower()
            status = re.split(r"\s*[(—:-]", status, maxsplit=1)[0].strip()
            evidence = cells[evidence_index]
            if (
                not _substantive(criterion)
                or status not in STATUS_VALUES
                or not _substantive(evidence)
            ):
                return False
            found_valid = True
    return found_table and found_valid


def _has_author_sha(body):
    return _author_sha(body) is not None


def _author_evidence_text(body):
    headings = []
    lines = []
    for line in _lines(body):
        heading = re.match(r"^\s{0,3}(#{1,6})\s+(.+)", line)
        if heading:
            level = len(heading.group(1))
            headings = [(depth, title) for depth, title in headings if depth < level]
            headings.append((level, heading.group(2)))
        role_titles = [title for _, title in headings if re.search(r"\b(?:reviewer|reviewed|integration|combined|ci|g4|g5)\b", title, re.IGNORECASE)]
        explicit_author = re.search(r"\b(?:verified\s+author[- ]tested\s+commit\s+sha|author[- ]tested\s+sha)\b", line, re.IGNORECASE)
        joint_context = role_titles and all(re.search(r"\bauthor\b", title, re.IGNORECASE) for title in role_titles)
        if not role_titles or (joint_context and explicit_author):
            lines.append(line)
    return "\n".join(lines)


def _author_sha(body):
    body = re.sub(r"(!?)\[([^]]*)\]\([^)]*\)", lambda match: "" if match.group(1) else match.group(2), body)
    body = re.sub(r"https?://\S+", "", body)
    body = _author_evidence_text(body)
    role_labels = re.compile(
        r"\b(?:verified\s+(?:author[- ]tested\s+)?commit\s+sha|author[- ]tested\s+sha|"
        r"reviewer[- ]reviewed\s+sha|reviewed\s+tested\s+sha|combined\s+integration\s+sha|"
        r"integration\s+sha|ci(?:[- ]tested)?\s+sha)\b",
        re.IGNORECASE,
    )
    author_labels = re.compile(
        r"\b(?:verified\s+(?:author[- ]tested\s+)?commit\s+sha|author[- ]tested\s+sha)\b",
        re.IGNORECASE,
    )
    for line in _lines(body):
        role_matches = list(role_labels.finditer(line))
        for label_match in author_labels.finditer(line):
            next_role = next(
                (candidate for candidate in role_matches if candidate.start() > label_match.end()),
                None,
            )
            suffix_end = next_role.start() if next_role else len(line)
            match = SHA_RE.search(line[label_match.end() : suffix_end])
            if match:
                return match.group(0).lower()
    verification = _section_text(body, ("verification", "verification fingerprint", "behavioral evidence")) or ""
    for line in _lines(verification):
        if re.search(r"\b(?:reviewer|reviewed|integration|combined|ci)\b", line, re.IGNORECASE):
            continue
        match = re.search(
            r"\b(?:built and deployed|built and tested|tested (?:commit|head))\s+[`*]*([0-9a-f]{40})(?![0-9a-f])",
            line, re.IGNORECASE,
        )
        if match:
            return match.group(1).lower()
    return None


def _has_environment(body):
    value = _section_text(body, ("environment", "platform"))
    if value is not None:
        return not re.search(r"os and platform;|simulated or physical device;|relevant flags", value, re.IGNORECASE) and _substantive(value, allow_none=True)
    verification = _section_text(body, ("verification fingerprint", "verification")) or ""
    return bool(re.search(
        r"\b(?:ubuntu|debian|linux|windows|macos|ios|android|physical|real de1|github repository content api)\b",
        verification, re.IGNORECASE,
    ))


def _has_commands(body):
    body = re.sub(r"(!?)\[([^]]*)\]\([^)]*\)", lambda match: "" if match.group(1) else match.group(2), body)
    body = re.sub(r"https?://\S+", "", body)
    values = []
    for labels in (("commands and results", "commands/results", "commands", "checks"),):
        value = _section_text(body, labels)
        if value:
            values.append(value)
    heading = _section_text(body, ("verification",))
    if heading:
        values.append(heading)
    evidence = []
    field_pattern = re.compile(r"^\s*(?:[-*]\s*)?(?:\*\*)?([A-Za-z][A-Za-z /_-]{2,70}?)(?:\*\*)?\s*:\s*(?:\*\*)?(.*)$")
    command_label = _label_pattern(("commands and results", "commands/results", "commands", "checks"))
    for line in _lines("\n".join(values)):
        if re.match(r"^\s*#{1,6}\s+", line):
            continue
        field = field_pattern.match(line)
        if field:
            if re.search(r"\b(?:sha|environment|platform|limitations?|known gaps|not tested|human validation|captures?|traces?|running-app)\b", field.group(1), re.IGNORECASE):
                continue
            if not _substantive(field.group(2)):
                continue
            if command_label.match(line):
                line = field.group(2)
        if SHA_RE.fullmatch(_clean(line).strip("- ")):
            continue
        if re.match(r"^(?:[-*]\s*)?(?:plan(?:ned)?\b|will\b|(?:run|execute)\b.*\bexpect(?:ed)?\b)", _clean(line), re.IGNORECASE):
            continue
        evidence.append(line)
    value = "\n".join(evidence)
    if not value or not _substantive(value):
        return False
    has_command = bool(
        re.search(r"`[^`]+`|\b(?:python|flutter|dart|bash|sh|make|true|false|git|node|checked|retrieved|inspected|validated|confirmed|tests?|suite|analysis|build)\b", value, re.IGNORECASE)
    )
    has_result = bool(
        re.search(
            r"pass|fail|exit\s*[0-9]+|success|error|not run|not tested|formatted|issues found|all tests passed|"
            r"retrieved and inspected|checked .* (?:consistency|vocabulary)|gates? finished|completed|inspected|validated|confirmed|verified by these tests",
            value,
            re.IGNORECASE,
        )
    )
    return has_command and has_result


def _has_limitations(body):
    value = _section_text(body, ("not tested / limitations / human validation needed", "limitations", "known gaps"))
    if value is not None:
        return not re.search(r"write none if none|known gaps?\s*\)?$", value, re.IGNORECASE) and _substantive(value, allow_none=True)
    prose = re.sub(r"\[[^]]*\]\([^)]*\)|https?://\S+", "", body)
    prose = " ".join(line.strip() for line in _lines(prose) if "|" not in line)
    return bool(re.search(
        r"\b(?:not (?:rerun|run|exercised|claimed)|remain(?:s)? (?:unverified|untested|unresolved)|"
        r"no (?:physical|real|hardware)[^.]{0,100}(?:validation|test|run)|"
        r"(?:builds?|environment|hardware)[^.]{0,60}unavailable|"
        r"(?:does|do) not [^.]{0,60}establish|(?:remaining|pending) (?:work|wiring|validation|verification))\b",
        prose, re.IGNORECASE,
    ))


def _has_responsibility_marker(body):
    marker = re.compile(
        r"^-\s*\[[xX]\].*<!--\s*contributor-responsibility\s*-->.*$",
        re.IGNORECASE,
    )
    return any(marker.match(line) for line in _lines(body))


def _scoped_reuse(body):
    return bool(
        re.search(
            r"(?:author|tested|evidence).{0,120}(?:scoped|unaffected|reused).{0,120}(?:path|file|documentation|change)"
            r"|(?:scoped|unaffected|reused).{0,120}(?:path|file|documentation|change).{0,120}(?:author|tested|evidence)",
            body,
            re.IGNORECASE | re.DOTALL,
        )
    )


def _valid_sha(value):
    return value is None or (isinstance(value, str) and re.fullmatch(r"[0-9a-f]{40}", value, re.IGNORECASE))


def inspect_body(body, head_sha=None, *, draft=False, external=False, association=None, author_type=None):
    if not isinstance(body, str):
        raise InputError("body must be text")
    if not _valid_sha(head_sha):
        raise InputError("head SHA must be a 40-character hexadecimal string")
    responsibility_body = _evidence_text(body, preserve_responsibility=True)
    body = _evidence_text(body)
    findings = []
    checks = (
        ("issue_reference", lambda value: _has_issue_or_exemption(value, association=association, author_type=author_type), "link an accepted issue or state a permitted maintainer/automation exemption"),
        ("risk_rationale", _has_risk_and_rationale, "state one L0–L3 risk level and a substantive rationale"),
        ("criteria_evidence", _has_criteria_evidence, "add substantive acceptance-criterion status/evidence rows without placeholders"),
        ("author_tested_sha", _has_author_sha, "record the author-tested Verified commit SHA"),
        ("environment", _has_environment, "state the environment/platform or a legitimate N/A"),
        ("commands_results", _has_commands, "record checks and observed results, including commands where applicable"),
        ("limitations", _has_limitations, "state limitations explicitly, including None/N/A when applicable"),
        ("responsibility_marker", _has_responsibility_marker, "retain the existing checked contributor-responsibility marker"),
    )
    for code, check, message in checks:
        evidence = responsibility_body if code == "responsibility_marker" else body
        if not check(evidence):
            findings.append(_finding(code, message))

    author_sha = _author_sha(body)
    normalized_head = head_sha.lower() if isinstance(head_sha, str) else None
    if normalized_head and author_sha and author_sha != normalized_head:
        findings.append(
            _finding(
                "stale_evidence",
                "author-tested evidence SHA differs from the PR head; review whether the older evidence remains in scope",
                scoped_reuse=_scoped_reuse(body),
            )
        )
    return {
        "findings": findings,
        "advisory": True,
        "draft": bool(draft),
        "external": bool(external),
        "author_tested_sha": author_sha,
    }


def load_event(path):
    try:
        with Path(path).open("r", encoding="utf-8") as stream:
            event = json.load(stream)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise InputError("event JSON could not be read") from error
    if not isinstance(event, dict) or not isinstance(event.get("pull_request"), dict):
        raise InputError("event JSON has no pull_request object")
    pull_request = event["pull_request"]
    body = pull_request.get("body")
    if body is None:
        body = ""
    if not isinstance(body, str):
        raise InputError("pull_request.body is not text")
    head = pull_request.get("head")
    if head is not None and not isinstance(head, dict):
        raise InputError("pull_request.head is not an object")
    head_sha = head.get("sha") if head is not None else None
    if not _valid_sha(head_sha):
        raise InputError("pull_request.head.sha is not a 40-character hexadecimal string")
    draft = pull_request.get("draft", False)
    if not isinstance(draft, bool):
        raise InputError("pull_request.draft is not boolean")
    user = pull_request.get("user")
    if user is not None and not isinstance(user, dict):
        raise InputError("pull_request.user is not an object")
    association = pull_request.get("author_association")
    if association is not None and not isinstance(association, str):
        raise InputError("pull_request.author_association is not text")
    author_type = user.get("type") if user is not None else None
    if author_type is not None and not isinstance(author_type, str):
        raise InputError("pull_request.user.type is not text")
    external = bool(
        isinstance(association, str)
        and association.upper() not in TRUSTED_ASSOCIATIONS
        and not (isinstance(author_type, str) and author_type.lower() == "bot")
    )
    return {
        "body": body,
        "head_sha": head_sha,
        "draft": draft,
        "external": external,
        "association": association,
        "author_type": author_type,
    }


def render_report(report):
    findings = report["findings"]
    lines = ["PR evidence validator: advisory report"]
    if not findings:
        lines.append("No advisory findings.")
    else:
        lines.append(f"{len(findings)} advisory finding(s):")
        for finding in findings:
            suffix = " (scoped older evidence)" if finding.get("scoped_reuse") else ""
            lines.append(f"- {finding['code']}: {finding['message']}{suffix}")
    return "\n".join(lines) + "\n"


def main(argv=None):
    parser = ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group()
    source.add_argument("--body", type=Path)
    source.add_argument("--event", type=Path)
    parser.add_argument("--head-sha")
    try:
        args = parser.parse_args(argv)
        if not _valid_sha(args.head_sha):
            raise InputError("head SHA must be a 40-character hexadecimal string")
        if args.event:
            values = load_event(args.event)
            body = values["body"]
            head_sha = args.head_sha if args.head_sha is not None else values["head_sha"]
            report = inspect_body(
                body,
                head_sha=head_sha,
                draft=values["draft"],
                external=values["external"],
                association=values["association"],
                author_type=values["author_type"],
            )
        elif args.body:
            try:
                body = args.body.read_text(encoding="utf-8")
            except (OSError, UnicodeError) as error:
                raise InputError("body input could not be read") from error
            report = inspect_body(body, head_sha=args.head_sha)
        elif os.environ.get("GITHUB_EVENT_PATH"):
            values = load_event(os.environ["GITHUB_EVENT_PATH"])
            report = inspect_body(
                values["body"],
                head_sha=args.head_sha if args.head_sha is not None else values["head_sha"],
                draft=values["draft"],
                external=values["external"],
                association=values["association"],
                author_type=values["author_type"],
            )
        else:
            raise InputError("provide --body, --event, or GITHUB_EVENT_PATH")
    except InputError as error:
        print(f"PR evidence validator: invalid event input ({error})", file=sys.stderr)
        return 2
    print(render_report(report), end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
