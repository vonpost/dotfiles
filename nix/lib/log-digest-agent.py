#!/usr/bin/env python3

import argparse
import copy
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter


def log_info(message: str) -> None:
    print(f"logDigest: {message}", flush=True)


def read_json_file(path: str):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def write_json_file(path: str, data) -> None:
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, sort_keys=True)
        handle.write("\n")


def write_text_file(path: str, content: str) -> None:
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(content)


def run_date_epoch(relative_expr: str) -> int:
    result = subprocess.run(
        ["date", "-u", "-d", relative_expr, "+%s"],
        check=True,
        capture_output=True,
        text=True,
    )
    return int(result.stdout.strip())


def now_utc_iso() -> str:
    result = subprocess.run(
        ["date", "-u", "--iso-8601=seconds"],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def now_utc_date() -> str:
    result = subprocess.run(
        ["date", "-u", "+%F"],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def parse_duration(text: str) -> float:
    stripped = text.strip()
    if stripped.isdigit():
        return float(stripped)
    units = {
        "s": 1,
        "m": 60,
        "h": 3600,
        "d": 86400,
    }
    unit = stripped[-1]
    value = stripped[:-1]
    if unit not in units or not value:
        raise ValueError(f"Unsupported duration: {text}")
    return float(value) * units[unit]


def http_json(url: str, *, method: str = "GET", params=None, payload=None, timeout: int = 180):
    if params:
        url = f"{url}?{urllib.parse.urlencode(params)}"
    request = urllib.request.Request(url, method=method)
    request.add_header("Accept", "application/json")
    body = None
    if payload is not None:
        request.add_header("Content-Type", "application/json")
        body = json.dumps(payload).encode("utf-8")
    with urllib.request.urlopen(request, data=body, timeout=timeout) as response:
        raw = response.read().decode("utf-8")
        return json.loads(raw)


def http_post_raw(url: str, payload, *, timeout: int = 60) -> None:
    request = urllib.request.Request(url, method="POST")
    request.add_header("Content-Type", "application/json")
    body = json.dumps(payload).encode("utf-8")
    with urllib.request.urlopen(request, data=body, timeout=timeout):
        return None


def normalize_whitespace(value) -> str:
    if value is None:
        return ""
    if isinstance(value, list):
        value = "".join(str(item) for item in value)
    text = str(value)
    return " ".join(text.split())


def extract_json_text(text: str) -> str:
    cleaned = text.strip()
    if cleaned.startswith("```"):
        cleaned = "\n".join(
            line for line in cleaned.splitlines() if not line.startswith("```")
        ).strip()
    if cleaned.startswith("{") or cleaned.startswith("["):
        return cleaned
    match = re.search(r"(\{.*\}|\[.*\])", cleaned, re.DOTALL)
    if match:
        return match.group(1).strip()
    return cleaned


def extract_message(entry: dict) -> str:
    return normalize_whitespace(entry.get("MESSAGE") or entry.get("message") or "")


def sort_repeat_groups(groups):
    return sorted(groups, key=lambda item: (-item["count"], item["vm"], item["unit"], item["message"]))


def aggregate_query_result(result_json, query, top_repeats: int, sample_lines: int):
    entries = []
    for stream in result_json.get("data", {}).get("result", []):
        stream_labels = stream.get("stream", {})
        for raw_value in stream.get("values", []):
            if len(raw_value) != 2:
                continue
            timestamp_raw, line_raw = raw_value
            try:
                payload = json.loads(line_raw)
            except json.JSONDecodeError:
                continue
            if not isinstance(payload, dict):
                continue
            if query.get("priorityMax") is not None:
                try:
                    priority_num = int(payload.get("PRIORITY"))
                except (TypeError, ValueError):
                    continue
                if priority_num > query["priorityMax"]:
                    continue
            message = extract_message(payload)
            if not message:
                continue
            vm = normalize_whitespace(payload.get("vm") or stream_labels.get("vm") or "-")
            unit = normalize_whitespace(payload.get("unit") or payload.get("service") or payload.get("SYSLOG_IDENTIFIER") or "-")
            priority = normalize_whitespace(payload.get("PRIORITY") or "-")
            try:
                ts = int(timestamp_raw)
            except (TypeError, ValueError):
                continue
            entries.append(
                {
                    "ts": ts,
                    "vm": vm,
                    "unit": unit,
                    "priority": priority,
                    "message": message,
                    "key": "\u0000".join([vm, unit, priority, message]),
                }
            )

    priority_counts = Counter(entry["priority"] for entry in entries if entry["priority"] != "-")
    repeats = {}
    for entry in entries:
        current = repeats.get(entry["key"])
        if current is None:
            repeats[entry["key"]] = {
                "key": entry["key"],
                "vm": entry["vm"],
                "unit": entry["unit"],
                "priority": entry["priority"],
                "message": entry["message"],
                "count": 1,
                "first_ts": entry["ts"],
                "last_ts": entry["ts"],
            }
            continue
        current["count"] += 1
        current["first_ts"] = min(current["first_ts"], entry["ts"])
        current["last_ts"] = max(current["last_ts"], entry["ts"])

    return {
        "title": query["title"],
        "expr": query["expr"],
        "priority_max": query.get("priorityMax"),
        "total_lines": len(entries),
        "unique_signatures": len({(entry["unit"], entry["message"]) for entry in entries}),
        "priority_counts": dict(sorted(priority_counts.items())),
        "observed_vms": sorted({entry["vm"] for entry in entries}),
        "observed_units": sorted({entry["unit"] for entry in entries}),
        "repeat_groups": sort_repeat_groups(list(repeats.values()))[:top_repeats],
        "sample_lines": [
            {
                "ts": entry["ts"],
                "vm": entry["vm"],
                "unit": entry["unit"],
                "priority": entry["priority"],
                "message": entry["message"],
            }
            for entry in sorted(entries, key=lambda item: item["ts"], reverse=True)[:sample_lines]
        ],
    }


def compact_text(text: str, limit: int) -> str:
    if limit < 4 or len(text) <= limit:
        return text
    return text[: limit - 3] + "..."


def compact_query_view(query, *, unit_limit: int, repeat_limit: int, sample_limit: int, text_limit: int):
    result = {
        "title": query.get("title"),
        "expr": compact_text(str(query.get("expr", "")), text_limit),
        "error": compact_text(str(query.get("error", "")), text_limit),
        "total_lines": query.get("total_lines"),
        "unique_signatures": query.get("unique_signatures"),
        "observed_units": [compact_text(str(item), text_limit) for item in (query.get("observed_units") or [])[:unit_limit]],
        "observed_vms": [compact_text(str(item), text_limit) for item in (query.get("observed_vms") or [])[:unit_limit]],
        "priority_counts": query.get("priority_counts", {}),
        "repeat_groups": [
            {
                "count": item.get("count"),
                "message": compact_text(str(item.get("message", "")), text_limit),
                "priority": item.get("priority"),
                "unit": compact_text(str(item.get("unit", "")), text_limit),
                "vm": compact_text(str(item.get("vm", "")), text_limit),
            }
            for item in (query.get("repeat_groups") or [])[:repeat_limit]
        ],
        "sample_lines": [
            {
                "message": compact_text(str(item.get("message", "")), text_limit),
                "priority": item.get("priority"),
                "ts": item.get("ts"),
                "unit": compact_text(str(item.get("unit", "")), text_limit),
                "vm": compact_text(str(item.get("vm", "")), text_limit),
            }
            for item in (query.get("sample_lines") or [])[:sample_limit]
        ],
    }
    return result


def build_query_error_result(query, error_text: str):
    return {
        "title": query["title"],
        "expr": query["expr"],
        "priority_max": query.get("priorityMax"),
        "error": normalize_whitespace(error_text),
        "total_lines": 0,
        "unique_signatures": 0,
        "priority_counts": {},
        "observed_vms": [],
        "observed_units": [],
        "repeat_groups": [],
        "sample_lines": [],
    }


def compact_snapshot(snapshot, level: int):
    if level == 0:
        return copy.deepcopy(snapshot)
    profiles = {
        1: (16, 24, 8, 8, 320),
        2: (12, 18, 6, 6, 240),
        3: (10, 14, 4, 4, 180),
        4: (8, 10, 3, 3, 140),
        5: (6, 8, 2, 2, 100),
    }
    query_limit, unit_limit, repeat_limit, sample_limit, text_limit = profiles.get(level, profiles[5])
    return {
        "generated_at": snapshot.get("generated_at"),
        "vm": snapshot.get("vm"),
        "window": snapshot.get("window"),
        "queries": [
            compact_query_view(
                query,
                unit_limit=unit_limit,
                repeat_limit=repeat_limit,
                sample_limit=sample_limit,
                text_limit=text_limit,
            )
            for query in (snapshot.get("queries") or [])[:query_limit]
        ],
    }


def compact_diff(diff_data, level: int):
    if level == 0:
        return copy.deepcopy(diff_data)
    profiles = {
        1: (16, 24, 8, 320),
        2: (12, 18, 6, 240),
        3: (10, 14, 4, 180),
        4: (8, 10, 3, 140),
        5: (6, 8, 2, 100),
    }
    query_limit, unit_limit, change_limit, text_limit = profiles.get(level, profiles[5])

    def compact_group(group):
        return {
            "current_count": group.get("current_count"),
            "delta_count": group.get("delta_count"),
            "key": compact_text(str(group.get("key", "")), text_limit),
            "message": compact_text(str(group.get("message", "")), text_limit),
            "previous_count": group.get("previous_count"),
            "priority": group.get("priority"),
            "state": group.get("state"),
            "unit": compact_text(str(group.get("unit", "")), text_limit),
            "vm": compact_text(str(group.get("vm", "")), text_limit),
        }

    return {
        "changed_query_count": diff_data.get("changed_query_count"),
        "generated_at": diff_data.get("generated_at"),
        "initial_run": diff_data.get("initial_run"),
        "previous_generated_at": diff_data.get("previous_generated_at"),
        "vm": diff_data.get("vm"),
        "queries": [
            {
                "has_changes": query.get("has_changes"),
                "new_repeat_groups": [compact_group(item) for item in (query.get("new_repeat_groups") or [])[:change_limit]],
                "new_units": [compact_text(str(item), text_limit) for item in (query.get("new_units") or [])[:unit_limit]],
                "gone_repeat_groups": [compact_group(item) for item in (query.get("gone_repeat_groups") or [])[:change_limit]],
                "gone_units": [compact_text(str(item), text_limit) for item in (query.get("gone_units") or [])[:unit_limit]],
                "repeat_group_changes": [compact_group(item) for item in (query.get("repeat_group_changes") or [])[:change_limit]],
                "title": query.get("title"),
                "total_lines": query.get("total_lines"),
                "unique_signatures": query.get("unique_signatures"),
            }
            for query in (diff_data.get("queries") or [])[:query_limit]
        ],
    }


def normalize_memory_body(data, run_date: str, include_meta: bool = False):
    def normalize_titles(values):
        result = sorted({normalize_whitespace(item) for item in values or [] if normalize_whitespace(item)})
        return result

    def normalize_issue(item, default_status: str):
        summary = normalize_whitespace(item.get("summary") or item.get("item") or item.get("title") or "")
        key = normalize_whitespace(item.get("key") or summary)
        if not summary:
            return None
        days_seen = item.get("days_seen", 1)
        try:
            days_seen = int(days_seen)
        except (TypeError, ValueError):
            days_seen = 1
        return {
            "key": key,
            "summary": summary,
            "status": normalize_whitespace(item.get("status") or default_status),
            "days_seen": days_seen,
            "last_seen": normalize_whitespace(item.get("last_seen") or run_date),
            "evidence": normalize_whitespace(item.get("evidence") or ""),
            "query_titles": normalize_titles(item.get("query_titles")),
        }

    def normalize_list(values, default_status):
        result = []
        for item in values or []:
            if not isinstance(item, dict):
                continue
            normalized = normalize_issue(item, default_status)
            if normalized is not None:
                result.append(normalized)
        return result[:10]

    normalized = {
        "active_issues": normalize_list(data.get("active_issues"), "ongoing"),
        "known_noise": normalize_list(data.get("known_noise"), "known"),
        "watch_items": normalize_list(data.get("watch_items"), "watch"),
    }
    if include_meta:
        meta = data.get("meta") or {}
        normalized["meta"] = {
            "content_sha256": meta.get("content_sha256"),
            "previous_snapshot_generated_at": meta.get("previous_snapshot_generated_at"),
            "source_snapshot_generated_at": meta.get("source_snapshot_generated_at"),
            "unchanged_runs": int(meta.get("unchanged_runs", 0) or 0),
            "updated_at": meta.get("updated_at"),
        }
    if normalize_whitespace(data.get("legacy_notes") or ""):
        normalized["legacy_notes"] = normalize_whitespace(data["legacy_notes"])
    return normalized


def normalize_previous_memory_text(text: str, run_date: str):
    if not text.strip():
        return {
            "active_issues": [],
            "known_noise": [],
            "meta": {
                "content_sha256": None,
                "previous_snapshot_generated_at": None,
                "source_snapshot_generated_at": None,
                "unchanged_runs": 0,
                "updated_at": None,
            },
            "watch_items": [],
        }
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        return {
            "active_issues": [],
            "known_noise": [],
            "meta": {
                "content_sha256": None,
                "previous_snapshot_generated_at": None,
                "source_snapshot_generated_at": None,
                "unchanged_runs": 0,
                "updated_at": None,
            },
            "watch_items": [],
            "legacy_notes": text,
        }
    return normalize_memory_body(data, run_date, include_meta=True)


def normalize_summary_json_text(text: str):
    data = json.loads(extract_json_text(text))

    def normalize_item(item):
        return {
            "item": normalize_whitespace(item.get("item") or item.get("summary") or item.get("title") or ""),
            "evidence": normalize_whitespace(item.get("evidence") or ""),
            "action": normalize_whitespace(item.get("action") or ""),
            "why_it_matters": normalize_whitespace(item.get("why_it_matters") or item.get("impact") or ""),
        }

    def normalize_list(values):
        result = []
        for item in values or []:
            if not isinstance(item, dict):
                continue
            normalized = normalize_item(item)
            if normalized["item"]:
                result.append(normalized)
        return result[:8]

    return {
        "overall": normalize_whitespace(data.get("overall") or data.get("summary") or ""),
        "key_findings": normalize_list(data.get("key_findings")),
        "new_issues": normalize_list(data.get("new_issues")),
        "ongoing_issues": normalize_list(data.get("ongoing_issues")),
        "resolved_or_changed": normalize_list(data.get("resolved_or_changed")),
        "routine_noise": normalize_list(data.get("routine_noise")),
        "interesting_patterns": normalize_list(data.get("interesting_patterns")),
        "investigation_notes": [
            {
                "item": normalize_whitespace(item.get("question") or item.get("item") or item.get("summary") or ""),
                "evidence": normalize_whitespace(item.get("answer") or item.get("evidence") or ""),
                "action": normalize_whitespace(item.get("next_step") or item.get("action") or ""),
                "why_it_matters": normalize_whitespace(item.get("why_it_matters") or item.get("impact") or ""),
            }
            for item in (data.get("investigation_notes") or [])
            if isinstance(item, dict) and normalize_whitespace(item.get("question") or item.get("item") or item.get("summary") or "")
        ][:8],
    }


def normalize_updated_memory_text(text: str, run_date: str):
    data = json.loads(extract_json_text(text))
    return normalize_memory_body(data, run_date, include_meta=False)


def render_summary_markdown(summary_json, generated_at: str) -> str:
    lines = [f"Generated (UTC): {generated_at}"]
    if summary_json.get("overall"):
        lines.extend(["", summary_json["overall"]])
    sections = [
        ("Key Findings", summary_json.get("key_findings") or []),
        ("New Issues", summary_json.get("new_issues") or []),
        ("Ongoing Issues", summary_json.get("ongoing_issues") or []),
        ("Resolved/Changed", summary_json.get("resolved_or_changed") or []),
        ("Interesting Patterns", summary_json.get("interesting_patterns") or []),
        ("Investigation Notes", summary_json.get("investigation_notes") or []),
        ("Routine Noise", summary_json.get("routine_noise") or []),
    ]
    for title, items in sections:
        if not items:
            continue
        lines.extend(["", f"## {title}"])
        for item in items:
            bullet = f"- {item['item']}"
            if item.get("why_it_matters"):
                bullet += f" | why: {item['why_it_matters']}"
            if item.get("evidence"):
                bullet += f" | evidence: {item['evidence']}"
            if item.get("action"):
                bullet += f" | action: {item['action']}"
            lines.append(bullet)
    return "\n".join(lines) + "\n"


def build_llama_request(cfg, messages, max_tokens: int, response_format=None):
    payload = {
        "model": cfg["model"],
        "messages": messages,
        "max_tokens": max_tokens,
        "temperature": cfg["temperature"],
        "chat_template_kwargs": {"enable_thinking": False},
        "reasoning": "off",
        "reasoning_format": "none",
    }
    if response_format is not None:
        payload["response_format"] = response_format
    return payload


def strip_think_wrappers(text: str) -> str:
    stripped = text.strip()
    prefix = "<think>\n\n</think>\n\n"
    if stripped.startswith(prefix):
        return stripped[len(prefix):].strip()
    if stripped.startswith("<think>"):
        stripped = re.sub(r"^<think>\s*</think>\s*", "", stripped, flags=re.DOTALL)
    return stripped


def extract_response_content(response, stage: str) -> str:
    choice = (response.get("choices") or [{}])[0]
    message = choice.get("message") or {}
    content = message.get("content")
    if isinstance(content, list):
        content = "".join(part.get("text", "") if isinstance(part, dict) else str(part) for part in content)
    content = strip_think_wrappers(content or "")
    if content:
        return content

    reasoning_content = normalize_whitespace(message.get("reasoning_content") or "")
    finish_reason = choice.get("finish_reason")
    response_preview = compact_text(json.dumps(response, sort_keys=True), 1200)
    raise RuntimeError(
        f"llama-server returned empty assistant content during {stage}; "
        f"finish_reason={finish_reason!r} reasoning_content_present={bool(reasoning_content)} response={response_preview}"
    )


def fetch_latest_digest(cfg, kind: str, start_ns: int, end_ns: int) -> str:
    response = http_json(
        f"{cfg['lokiUrl']}/loki/api/v1/query_range",
        params={
            "query": f'{{vm="{cfg["digestVm"]}",service="logDigest",kind="{kind}"}}',
            "start": str(start_ns),
            "end": str(end_ns),
            "limit": "1",
            "direction": "backward",
        },
        timeout=60,
    )
    try:
        return response["data"]["result"][0]["values"][0][1]
    except (KeyError, IndexError, TypeError):
        return ""


def push_digest(cfg, now_ns: int, kind: str, content: str) -> None:
    payload = {
        "streams": [
            {
                "stream": {
                    "vm": cfg["digestVm"],
                    "service": "logDigest",
                    "kind": kind,
                    "source_type": "digest",
                },
                "values": [[str(now_ns), content]],
            }
        ]
    }
    http_post_raw(f"{cfg['lokiUrl']}/loki/api/v1/push", payload)


def request_llama(cfg, payload, stage: str):
    attempts = 0
    max_attempts = 1 + int(cfg["gpuBusyRetryCount"])
    while attempts < max_attempts:
        request = urllib.request.Request(
            f"{cfg['url']}:{cfg['port']}{cfg['endpoint']}",
            method="POST",
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=int(cfg["llamaRequestTimeoutSeconds"])) as response:
                return json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            log_info(f"llama-server response during {stage} (HTTP {exc.code})")
            if body:
                print(body, file=sys.stderr)
            retryable = False
            try:
                retryable = json.loads(body).get("error", {}).get("type") == "exceed_context_size_error"
            except json.JSONDecodeError:
                retryable = False
            if retryable and attempts < max_attempts - 1:
                delay_seconds = parse_duration(cfg["gpuBusyRetryDelay"])
                log_info(f"retryable context-size error during {stage}, sleeping {cfg['gpuBusyRetryDelay']}")
                time.sleep(delay_seconds)
                attempts += 1
                continue
            raise
        except urllib.error.URLError as exc:
            raise RuntimeError(f"llama-server request failed during {stage}: {exc}") from exc
    raise RuntimeError(f"llama-server request failed during {stage}")


def calc_prompt_char_budget(context_window: int, max_tokens: int, cfg) -> int:
    available_tokens = max(context_window - int(cfg["contextReserveTokens"]) - max_tokens, 1024)
    return max(
        int(available_tokens * int(cfg["charsPerTokenEstimate"]) * int(cfg["promptBudgetPercent"]) / 100),
        8192,
    )


def clamp_max_tokens(context_window: int, requested: int, cfg) -> int:
    max_allowed = max(context_window - int(cfg["contextReserveTokens"]), 256)
    return min(requested, max_allowed)


def summarize_query_for_prompt(query):
    return compact_query_view(
        query,
        unit_limit=24,
        repeat_limit=query.get("repeat_limit", 8),
        sample_limit=query.get("sample_limit", 8),
        text_limit=320,
    )


def query_index(queries):
    return {query["title"]: query for query in queries}


def group_index(query):
    return {group["key"]: group for group in query.get("repeat_groups") or []}


def diff_groups(current_groups, previous_groups):
    result = []
    for key in set(current_groups) | set(previous_groups):
        current = current_groups.get(key)
        previous = previous_groups.get(key)
        state = "unchanged"
        if previous is None:
            state = "new"
        elif current is None:
            state = "gone"
        elif (current.get("count") or 0) != (previous.get("count") or 0):
            state = "changed"
        if state == "unchanged":
            continue
        result.append(
            {
                "current_count": (current or {}).get("count", 0),
                "delta_count": (current or {}).get("count", 0) - (previous or {}).get("count", 0),
                "key": key,
                "message": (current or previous or {}).get("message", ""),
                "previous_count": (previous or {}).get("count", 0),
                "priority": (current or previous or {}).get("priority", "-"),
                "state": state,
                "unit": (current or previous or {}).get("unit", "-"),
                "vm": (current or previous or {}).get("vm", "-"),
            }
        )
    return sorted(result, key=lambda item: (-abs(item["delta_count"]), item["state"], item["unit"], item["message"]))


def build_diff(current_snapshot, previous_snapshot, change_limit: int):
    previous_by_title = query_index(previous_snapshot.get("queries") or [])
    queries = []
    for query in current_snapshot.get("queries") or []:
        previous = previous_by_title.get(query["title"], {})
        group_diffs = diff_groups(group_index(query), group_index(previous))
        queries.append(
            {
                "has_changes": (
                    query.get("total_lines") != previous.get("total_lines", 0)
                    or query.get("unique_signatures") != previous.get("unique_signatures", 0)
                    or (query.get("observed_units") or []) != (previous.get("observed_units") or [])
                    or bool(group_diffs)
                ),
                "new_repeat_groups": [item for item in group_diffs if item["state"] == "new"][:change_limit],
                "new_units": [item for item in (query.get("observed_units") or []) if item not in (previous.get("observed_units") or [])],
                "gone_repeat_groups": [item for item in group_diffs if item["state"] == "gone"][:change_limit],
                "gone_units": [item for item in (previous.get("observed_units") or []) if item not in (query.get("observed_units") or [])],
                "repeat_group_changes": [item for item in group_diffs if item["state"] == "changed"][:change_limit],
                "title": query["title"],
                "total_lines": {
                    "current": query.get("total_lines", 0),
                    "delta": query.get("total_lines", 0) - previous.get("total_lines", 0),
                    "previous": previous.get("total_lines", 0),
                },
                "unique_signatures": {
                    "current": query.get("unique_signatures", 0),
                    "delta": query.get("unique_signatures", 0) - previous.get("unique_signatures", 0),
                    "previous": previous.get("unique_signatures", 0),
                },
            }
        )
    changed_query_count = sum(1 for item in queries if item["has_changes"])
    return {
        "changed_query_count": changed_query_count,
        "generated_at": current_snapshot.get("generated_at"),
        "initial_run": previous_snapshot.get("generated_at") is None,
        "previous_generated_at": previous_snapshot.get("generated_at"),
        "queries": queries,
        "vm": current_snapshot.get("vm"),
    }


def compact_memory(memory_data, level: int):
    if level == 0:
        return copy.deepcopy(memory_data)
    profiles = {
        1: (10, 12, 320),
        2: (8, 10, 240),
        3: (6, 8, 180),
        4: (5, 6, 140),
        5: (4, 5, 100),
    }
    item_limit, title_limit, text_limit = profiles.get(level, profiles[5])

    def compact_item(item):
        return {
            "key": compact_text(item.get("key", ""), text_limit),
            "summary": compact_text(item.get("summary", ""), text_limit),
            "status": compact_text(item.get("status", ""), title_limit),
            "days_seen": item.get("days_seen"),
            "last_seen": item.get("last_seen"),
            "evidence": compact_text(item.get("evidence", ""), text_limit),
            "query_titles": [compact_text(title, title_limit) for title in (item.get("query_titles") or [])[:title_limit]],
        }

    result = {
        "active_issues": [compact_item(item) for item in (memory_data.get("active_issues") or [])[:item_limit]],
        "known_noise": [compact_item(item) for item in (memory_data.get("known_noise") or [])[:item_limit]],
        "watch_items": [compact_item(item) for item in (memory_data.get("watch_items") or [])[:item_limit]],
    }
    if "meta" in memory_data:
        result["meta"] = memory_data["meta"]
    if "legacy_notes" in memory_data:
        result["legacy_notes"] = compact_text(memory_data["legacy_notes"], text_limit * 2)
    return result


def compact_investigation_trace(trace, level: int):
    if level == 0:
        return copy.deepcopy(trace)
    text_limit = {1: 320, 2: 240, 3: 180, 4: 140, 5: 100}.get(level, 100)
    round_limit = {1: 8, 2: 6, 3: 5, 4: 4, 5: 3}.get(level, 3)
    query_limit = {1: 6, 2: 5, 3: 4, 4: 3, 5: 2}.get(level, 2)
    compacted = []
    for round_item in trace[:round_limit]:
        compacted.append(
            {
                "round": round_item.get("round"),
                "decision": round_item.get("decision"),
                "focus": compact_text(round_item.get("focus", ""), text_limit),
                "queries": [
                    compact_query_view(
                        query,
                        unit_limit=12,
                        repeat_limit=4,
                        sample_limit=4,
                        text_limit=text_limit,
                    )
                    for query in (round_item.get("queries") or [])[:query_limit]
                ],
            }
        )
    return compacted


def build_summary_request(cfg, previous_memory, snapshot, diff_data, investigation_trace, max_tokens: int):
    return build_llama_request(
        cfg,
        [
            {
                "role": "system",
                "content": (
                    "You are producing an operator-style investigative digest for a homelab. "
                    "Base the digest on the structured diff, baseline snapshot, and follow-up query evidence. "
                    "Think like an SRE writing up what they checked, what looks new, what stayed noisy, and what still deserves attention. "
                    "Use the follow-up investigation to pursue suspicious changes, but do not invent incidents without evidence. "
                    "Return JSON only with this schema: "
                    "{overall:string,key_findings:[{item,why_it_matters,evidence,action}],new_issues:[{item,why_it_matters,evidence,action}],ongoing_issues:[{item,why_it_matters,evidence,action}],resolved_or_changed:[{item,why_it_matters,evidence,action}],interesting_patterns:[{item,why_it_matters,evidence,action}],investigation_notes:[{question,answer,why_it_matters,next_step}],routine_noise:[{item,why_it_matters,evidence,action}]}. "
                    "Write overall as 3-6 crisp sentences, not a headline fragment. "
                    "Prefer concrete observations over category labels. "
                    "Use key_findings for the most important things you actually learned from investigation. "
                    "Use investigation_notes for questions you checked, what the evidence suggested, and what still needs checking. "
                    "Keep strings compact but informative, and keep arrays empty when absent."
                ),
            },
            {
                "role": "user",
                "content": (
                    "Previous rolling memory JSON:\n"
                    + json.dumps(previous_memory, sort_keys=True)
                    + "\n\nCurrent snapshot JSON:\n"
                    + json.dumps(snapshot, sort_keys=True)
                    + "\n\nDay-over-day diff JSON:\n"
                    + json.dumps(diff_data, sort_keys=True)
                    + "\n\nFollow-up investigation JSON:\n"
                    + json.dumps({"rounds": investigation_trace}, sort_keys=True)
                ),
            },
        ],
        max_tokens,
        response_format={"type": "json_object"},
    )


def build_memory_request(cfg, previous_memory, snapshot, diff_data, investigation_trace, summary_json, max_tokens: int):
    return build_llama_request(
        cfg,
        [
            {
                "role": "system",
                "content": (
                    "Update rolling memory for future daily digests. "
                    "Return JSON only with this schema: "
                    "{active_issues:[{key,summary,status,days_seen,last_seen,evidence,query_titles}],known_noise:[{key,summary,status,days_seen,last_seen,evidence,query_titles}],watch_items:[{key,summary,status,days_seen,last_seen,evidence,query_titles}]}. "
                    "Keep only durable context. Remove stale one-off incidents that no longer matter. "
                    "Reuse keys for continuing items. Use YYYY-MM-DD for last_seen. Keep each array compact."
                ),
            },
            {
                "role": "user",
                "content": (
                    "Previous rolling memory JSON:\n"
                    + json.dumps(previous_memory, sort_keys=True)
                    + "\n\nCurrent snapshot JSON:\n"
                    + json.dumps(snapshot, sort_keys=True)
                    + "\n\nDay-over-day diff JSON:\n"
                    + json.dumps(diff_data, sort_keys=True)
                    + "\n\nFollow-up investigation JSON:\n"
                    + json.dumps({"rounds": investigation_trace}, sort_keys=True)
                    + "\n\nSummary JSON for today:\n"
                    + json.dumps(summary_json, sort_keys=True)
                ),
            },
        ],
        max_tokens,
        response_format={"type": "json_object"},
    )


def fit_request_to_budget(builder, budget: int):
    for level in range(0, 6):
        payload = builder(level)
        size = len(json.dumps(payload, sort_keys=True))
        if size <= budget:
            return payload, size, level
    payload = builder(5)
    return payload, len(json.dumps(payload, sort_keys=True)), 5


def quote_logql_string(text: str) -> str:
    return text.replace("\\", "\\\\").replace("\"", "\\\"")


def normalize_followup_expr(expr: str) -> str:
    normalized = normalize_whitespace(expr)
    match = re.match(r"^\(\s*(\{.*\})\s*\)\s*((?:\|=|\|~|!=|!~).*)$", normalized)
    if match:
        return f"{match.group(1)} {match.group(2)}"
    return normalized


def compact_message_snippet(text: str, limit: int = 80) -> str:
    return compact_text(normalize_whitespace(text), limit)


def extract_focus_needle(text: str) -> str:
    normalized = normalize_whitespace(text)
    if not normalized:
        return ""

    match = re.search(r"msg=\"([^\"]{8,120})\"", normalized)
    if match:
        return compact_text(match.group(1), 80)

    prefixes = (
        "SQLite Error 5",
        "SQLite Error",
        "unable to delete/modify user",
        "INP_WAN_DROP",
        "RssSyncService",
        "DownloadDecisionMaker",
        "Torznab:",
        "HTTP Error - Res:",
        "nginx_access:",
        "PulseAudio",
        "ffmpeg",
        "stack trace",
        "EOF",
    )
    lower = normalized.lower()
    for prefix in prefixes:
        if prefix.lower() in lower:
            return prefix

    if ": " in normalized:
        head = normalized.split(": ", 1)[0].strip()
        if 6 <= len(head) <= 80:
            return head

    words = re.findall(r"[A-Za-z0-9_./:-]+", normalized)
    if not words:
        return ""
    return compact_text(" ".join(words[:6]), 80)


def build_investigation_leads(snapshot, diff_data):
    baseline_by_title = {query.get("title"): query for query in (snapshot.get("queries") or [])}
    leads = []
    for query in diff_data.get("queries") or []:
        if not query.get("has_changes"):
            continue
        baseline = baseline_by_title.get(query.get("title"), {})
        baseline_expr = baseline.get("expr")
        lead = {
            "title": query.get("title"),
            "baseline_expr": baseline_expr,
            "changed_total_lines": query.get("total_lines", {}).get("delta", 0),
            "changed_unique_signatures": query.get("unique_signatures", {}).get("delta", 0),
            "new_units": (query.get("new_units") or [])[:4],
            "gone_units": (query.get("gone_units") or [])[:4],
            "top_changes": [],
            "candidate_queries": [],
        }

        combined_changes = []
        combined_changes.extend(query.get("new_repeat_groups") or [])
        combined_changes.extend(query.get("repeat_group_changes") or [])
        combined_changes = sorted(
            combined_changes,
            key=lambda item: -abs(int(item.get("delta_count", 0) or 0)),
        )

        for item in combined_changes[:3]:
            snippet = compact_message_snippet(item.get("message", ""))
            unit = compact_text(str(item.get("unit", "")), 40)
            delta = int(item.get("delta_count", 0) or 0)
            lead["top_changes"].append(
                {
                    "delta_count": delta,
                    "message": snippet,
                    "unit": unit,
                    "priority": item.get("priority"),
                }
            )
            focus_needle = extract_focus_needle(item.get("message", ""))
            if baseline_expr and focus_needle:
                narrowed_expr = normalize_followup_expr(
                    f"{baseline_expr} |= \"{quote_logql_string(focus_needle)}\""
                )
                lead["candidate_queries"].append(
                    {
                        "title": f"{query.get('title')} focus {len(lead['candidate_queries'])}",
                        "expr": narrowed_expr,
                        "priority_max": None,
                        "reason": f"Check whether '{focus_needle}' is persistent or isolated.",
                    }
                )

        if baseline_expr:
            lead["candidate_queries"].append(
                {
                    "title": f"{query.get('title')} recent baseline",
                    "expr": baseline_expr,
                    "priority_max": None,
                    "reason": "Re-scan the full changed bucket before narrowing.",
                }
            )

        deduped = []
        seen = set()
        for item in lead["candidate_queries"]:
            key = (item["title"], item["expr"], item.get("priority_max"))
            if key in seen:
                continue
            seen.add(key)
            deduped.append(item)
        lead["candidate_queries"] = deduped[:4]
        leads.append(lead)

    return leads[:6]


def bootstrap_queries_from_leads(leads, queries_left: int, max_queries_per_round: int):
    selected = []
    seen_expr = set()
    limit = min(queries_left, max_queries_per_round)
    for lead in leads:
        for candidate in lead.get("candidate_queries") or []:
            expr = candidate.get("expr")
            title = candidate.get("title")
            if not expr or not title or expr in seen_expr:
                continue
            seen_expr.add(expr)
            selected.append(
                {
                    "title": title,
                    "expr": expr,
                    "priorityMax": candidate.get("priority_max"),
                }
            )
            break
        if len(selected) >= limit:
            break
    return selected


def build_refinement_queries_from_round_results(round_results, queries_left: int, max_queries_per_round: int):
    selected = []
    seen_expr = set()
    limit = min(queries_left, max_queries_per_round)
    for result in round_results:
        base_expr = result.get("expr")
        if not base_expr or base_expr in seen_expr:
            continue

        candidate_messages = []
        for item in (result.get("repeat_groups") or [])[:3]:
            candidate_messages.append(item.get("message", ""))
        for item in (result.get("sample_lines") or [])[:3]:
            candidate_messages.append(item.get("message", ""))

        for message in candidate_messages:
            focus_needle = extract_focus_needle(message)
            if not focus_needle:
                continue
            narrowed_expr = normalize_followup_expr(
                f"{base_expr} |= \"{quote_logql_string(focus_needle)}\""
            )
            if narrowed_expr in seen_expr or narrowed_expr == base_expr:
                continue
            seen_expr.add(narrowed_expr)
            selected.append(
                {
                    "title": f"{result.get('title')} refine {len(selected) + 1}",
                    "expr": narrowed_expr,
                    "priorityMax": result.get("priority_max"),
                }
            )
            break

        if len(selected) >= limit:
            break
    return selected


UNSUPPORTED_FOLLOWUP_QUERY_TERMS = (
    "count_values",
    "line_format",
    "label_format",
    "unwrap",
    "quantile_over_time",
    "avg_over_time",
    "sum_over_time",
    "bytes_over_time",
    "rate(",
    "rate ",
    "sum(",
    "avg(",
    "topk(",
    "bottomk(",
    " by (",
    " without (",
    " regexp ",
    "| regexp",
    " json",
    "| json",
    " logfmt",
    "| logfmt",
    " pattern ",
    "| pattern",
)


def followup_query_support_error(expr: str) -> str:
    normalized = normalize_whitespace(expr).lower()
    for term in UNSUPPORTED_FOLLOWUP_QUERY_TERMS:
        if term in normalized:
            return (
                "unsupported follow-up query shape; only plain log selectors with optional "
                "filter operators (|=, |~, !=, !~) are allowed"
            )
    return ""


def build_planner_request(
    cfg,
    previous_memory,
    snapshot,
    diff_data,
    investigation_trace,
    investigation_leads,
    rounds_left: int,
    queries_left: int,
    time_remaining_seconds: int,
):
    return build_llama_request(
        cfg,
        [
            {
                "role": "system",
                "content": (
                    "You investigate homelab logs like an SRE debugging a live system. "
                    "You may either request more LogQL queries or finalize. "
                    "Return JSON only with this schema: "
                    "{decision:\"query\"|\"finalize\",focus:string,queries:[{title:string,expr:string,priority_max:number|null}]}. "
                    "Follow-up queries must stay within plain log queries only: a stream selector plus optional log filters like |=, |~, !=, or !~. "
                    "Do not use metric aggregations, count_values, line_format, label_format, regexp capture, json/logfmt extraction, unwrap, sum, avg, rate, topk, or by/without clauses. "
                    "When requesting queries, choose only queries that materially improve confidence in the digest. "
                    "Prefer queries that answer questions like: what changed, how widespread it is, whether it is ongoing, whether it correlates with one service or VM, and whether it looks operationally important. "
                    "Do not ask for more than the remaining query budget. "
                    "If changed_query_count is non-zero and no follow-up queries have run yet, prefer decision=query unless every change is obviously routine noise already covered by rolling memory. "
                    "If a prior follow-up query returned a broad bucket with many unique signatures or near-limit line counts, prefer another narrower query before finalizing. "
                    "If there is still ambiguity about scope, persistence, or impact, keep investigating instead of summarizing early. "
                    "Use the candidate_queries when they are useful, but you may also write your own LogQL. "
                    "If the evidence is already sufficient, return decision=finalize."
                ),
            },
            {
                "role": "user",
                "content": (
                    f"Rounds remaining: {rounds_left}\n"
                    f"Follow-up queries remaining: {queries_left}\n\n"
                    f"Time remaining before forced shutdown: about {time_remaining_seconds} seconds\n\n"
                    "Previous rolling memory JSON:\n"
                    + json.dumps(previous_memory, sort_keys=True)
                    + "\n\nCurrent snapshot JSON:\n"
                    + json.dumps(snapshot, sort_keys=True)
                    + "\n\nDay-over-day diff JSON:\n"
                    + json.dumps(diff_data, sort_keys=True)
                    + "\n\nSuspicious leads and candidate follow-up queries JSON:\n"
                    + json.dumps({"leads": investigation_leads}, sort_keys=True)
                    + "\n\nFollow-up investigation JSON:\n"
                    + json.dumps({"rounds": investigation_trace}, sort_keys=True)
                ),
            },
        ],
        int(cfg["investigationPlannerMaxTokens"]),
        response_format={"type": "json_object"},
    )


def planner_snapshot_view(snapshot):
    return {
        "generated_at": snapshot.get("generated_at"),
        "vm": snapshot.get("vm"),
        "window": snapshot.get("window"),
        "queries": [
            {
                "title": query.get("title"),
                "total_lines": query.get("total_lines"),
                "unique_signatures": query.get("unique_signatures"),
                "observed_units": (query.get("observed_units") or [])[:4],
                "observed_vms": (query.get("observed_vms") or [])[:4],
                "priority_counts": query.get("priority_counts", {}),
                "repeat_groups": [
                    {
                        "count": group.get("count"),
                        "message": compact_text(str(group.get("message", "")), 120),
                        "priority": group.get("priority"),
                        "unit": compact_text(str(group.get("unit", "")), 60),
                        "vm": compact_text(str(group.get("vm", "")), 40),
                    }
                    for group in (query.get("repeat_groups") or [])[:2]
                ],
            }
            for query in (snapshot.get("queries") or [])[:6]
        ],
    }


def planner_diff_view(diff_data):
    changed_queries = [query for query in (diff_data.get("queries") or []) if query.get("has_changes")]
    return {
        "changed_query_count": diff_data.get("changed_query_count"),
        "generated_at": diff_data.get("generated_at"),
        "initial_run": diff_data.get("initial_run"),
        "previous_generated_at": diff_data.get("previous_generated_at"),
        "vm": diff_data.get("vm"),
        "queries": [
            {
                "title": query.get("title"),
                "total_lines": query.get("total_lines"),
                "unique_signatures": query.get("unique_signatures"),
                "new_units": (query.get("new_units") or [])[:4],
                "gone_units": (query.get("gone_units") or [])[:4],
                "new_repeat_groups": [
                    {
                        "delta_count": item.get("delta_count"),
                        "message": compact_text(str(item.get("message", "")), 120),
                        "priority": item.get("priority"),
                        "unit": compact_text(str(item.get("unit", "")), 60),
                        "vm": compact_text(str(item.get("vm", "")), 40),
                    }
                    for item in (query.get("new_repeat_groups") or [])[:2]
                ],
                "repeat_group_changes": [
                    {
                        "delta_count": item.get("delta_count"),
                        "message": compact_text(str(item.get("message", "")), 120),
                        "priority": item.get("priority"),
                        "unit": compact_text(str(item.get("unit", "")), 60),
                        "vm": compact_text(str(item.get("vm", "")), 40),
                    }
                    for item in (query.get("repeat_group_changes") or [])[:2]
                ],
            }
            for query in changed_queries[:6]
        ],
    }


def planner_memory_view(memory_data):
    return {
        "active_issues": [
            {
                "summary": compact_text(item.get("summary", ""), 160),
                "status": compact_text(item.get("status", ""), 40),
                "days_seen": item.get("days_seen"),
                "query_titles": (item.get("query_titles") or [])[:3],
            }
            for item in (memory_data.get("active_issues") or [])[:4]
        ],
        "known_noise": [
            {
                "summary": compact_text(item.get("summary", ""), 160),
                "status": compact_text(item.get("status", ""), 40),
                "days_seen": item.get("days_seen"),
                "query_titles": (item.get("query_titles") or [])[:3],
            }
            for item in (memory_data.get("known_noise") or [])[:4]
        ],
        "watch_items": [
            {
                "summary": compact_text(item.get("summary", ""), 160),
                "status": compact_text(item.get("status", ""), 40),
                "days_seen": item.get("days_seen"),
                "query_titles": (item.get("query_titles") or [])[:3],
            }
            for item in (memory_data.get("watch_items") or [])[:4]
        ],
    }


def fit_planner_request_to_budget(cfg, previous_memory, snapshot, diff_data, investigation_trace, investigation_leads, rounds_left: int, queries_left: int, time_remaining_seconds: int):
    prompt_budget = int(cfg["investigationPlannerMaxPromptChars"])
    for level in range(2, 6):
        payload = build_planner_request(
            cfg,
            planner_memory_view(compact_memory(previous_memory, level)),
            planner_snapshot_view(compact_snapshot(snapshot, level)),
            planner_diff_view(compact_diff(diff_data, level)),
            compact_investigation_trace(investigation_trace, level),
            investigation_leads,
            rounds_left,
            queries_left,
            time_remaining_seconds,
        )
        size = len(json.dumps(payload, sort_keys=True))
        if size <= prompt_budget:
            return payload, size, level
    payload = build_planner_request(
        cfg,
        planner_memory_view(compact_memory(previous_memory, 5)),
        planner_snapshot_view(compact_snapshot(snapshot, 5)),
        planner_diff_view(compact_diff(diff_data, 5)),
        compact_investigation_trace(investigation_trace, 5),
        investigation_leads,
        rounds_left,
        queries_left,
        time_remaining_seconds,
    )
    return payload, len(json.dumps(payload, sort_keys=True)), 5


def normalize_planner_response(text: str):
    data = json.loads(extract_json_text(text))
    decision = data.get("decision")
    if decision not in ("query", "finalize"):
        decision = "finalize"
    queries = []
    for item in data.get("queries") or []:
        if not isinstance(item, dict):
            continue
        title = normalize_whitespace(item.get("title") or "")
        expr = normalize_followup_expr(item.get("expr") or "")
        if not title or not expr:
            continue
        priority_max = item.get("priority_max")
        if priority_max is not None:
            try:
                priority_max = int(priority_max)
            except (TypeError, ValueError):
                priority_max = None
        queries.append({"title": title, "expr": expr, "priorityMax": priority_max})
    return {
        "decision": decision,
        "focus": normalize_whitespace(data.get("focus") or ""),
        "queries": queries,
    }


def build_investigation(cfg, *, previous_memory, snapshot, diff_data, start_ns: int, end_ns: int):
    if not cfg["investigationEnable"]:
        return []

    trace = []
    investigation_leads = build_investigation_leads(snapshot, diff_data)
    started_at = time.monotonic()
    total_queries = 0
    max_rounds = int(cfg["investigationMaxRounds"])
    max_total_queries = int(cfg["investigationMaxTotalQueries"])
    max_queries_per_round = int(cfg["investigationMaxQueriesPerRound"])
    run_budget_seconds = int(cfg["runBudgetSeconds"])
    shutdown_warning_seconds = int(cfg["shutdownWarningSeconds"])
    min_query_rounds_when_changed = 3

    for round_number in range(1, max_rounds + 1):
        queries_left = max_total_queries - total_queries
        if queries_left <= 0:
            break
        elapsed = int(time.monotonic() - started_at)
        time_remaining_seconds = run_budget_seconds - elapsed
        if time_remaining_seconds <= 0:
            log_info("investigation run budget exhausted, finalizing with collected evidence")
            break
        if time_remaining_seconds <= shutdown_warning_seconds:
            log_info(
                f"investigation nearing shutdown window ({time_remaining_seconds}s left), asking the model to finalize"
            )
            trace.append(
                {
                    "round": round_number,
                    "decision": "finalize",
                    "focus": f"Shutting down soon with about {time_remaining_seconds}s remaining",
                    "queries": [],
                }
            )
            break

        planner_payload, planner_size, planner_level = fit_planner_request_to_budget(
            cfg,
            previous_memory,
            snapshot,
            diff_data,
            trace,
            investigation_leads,
            rounds_left=max_rounds - round_number + 1,
            queries_left=queries_left,
            time_remaining_seconds=time_remaining_seconds,
        )
        log_info(
            f"planner request chars={planner_size} budget={cfg['investigationPlannerMaxPromptChars']} compaction_level={planner_level}"
        )
        planner_response = request_llama(cfg, planner_payload, f"investigation planning round {round_number}")
        try:
            planner_text = extract_response_content(planner_response, f"investigation planning round {round_number}")
            plan = normalize_planner_response(planner_text)
        except (RuntimeError, json.JSONDecodeError, TypeError, ValueError):
            log_info(
                "planner returned invalid or empty response in round %s, stopping investigation"
                % round_number
            )
            break

        if plan["decision"] != "query":
            if not trace and diff_data.get("changed_query_count", 0) > 0:
                selected_queries = bootstrap_queries_from_leads(
                    investigation_leads,
                    queries_left=queries_left,
                    max_queries_per_round=max_queries_per_round,
                )
                if selected_queries:
                    log_info(
                        "planner finalized immediately; bootstrapping %s lead-driven queries"
                        % len(selected_queries)
                    )
                    plan = {
                        "decision": "query",
                        "focus": "Bootstrap investigation from changed query buckets",
                        "queries": selected_queries,
                    }
                else:
                    trace.append({"round": round_number, "decision": "finalize", "focus": plan.get("focus", ""), "queries": []})
                    break
            else:
                query_rounds = [
                    item for item in trace if item.get("decision") == "query" and (item.get("queries") or [])
                ]
                if (
                    diff_data.get("changed_query_count", 0) > 0
                    and len(query_rounds) < min_query_rounds_when_changed
                    and queries_left > 0
                ):
                    refinement_queries = build_refinement_queries_from_round_results(
                        query_rounds[-1]["queries"],
                        queries_left=queries_left,
                        max_queries_per_round=max_queries_per_round,
                    )
                    if refinement_queries:
                        log_info(
                            "planner tried to finalize after %s query round(s); forcing %s refinement queries"
                            % (len(query_rounds), len(refinement_queries))
                        )
                        plan = {
                            "decision": "query",
                            "focus": "Refine broad follow-up results before finalizing",
                            "queries": refinement_queries,
                        }
                    else:
                        trace.append({"round": round_number, "decision": "finalize", "focus": plan.get("focus", ""), "queries": []})
                        break
                else:
                    trace.append({"round": round_number, "decision": "finalize", "focus": plan.get("focus", ""), "queries": []})
                    break

        selected_queries = plan["queries"][: min(max_queries_per_round, queries_left)]
        filtered_queries = []
        rejected_queries = []
        for query in selected_queries:
            support_error = followup_query_support_error(query["expr"])
            if support_error:
                log_info(
                    "planner proposed unsupported query: title=%r expr=%r error=%s"
                    % (query["title"], query["expr"], support_error)
                )
                rejected_queries.append(build_query_error_result(query, support_error))
                continue
            filtered_queries.append(query)
        selected_queries = filtered_queries
        if not selected_queries:
            if trace and diff_data.get("changed_query_count", 0) > 0 and queries_left > 0:
                refinement_queries = build_refinement_queries_from_round_results(
                    trace[-1].get("queries") or [],
                    queries_left=queries_left,
                    max_queries_per_round=max_queries_per_round,
                )
                if refinement_queries:
                    log_info(
                        "planner returned no usable queries; substituting %s refinement queries"
                        % len(refinement_queries)
                    )
                    selected_queries = refinement_queries[: min(max_queries_per_round, queries_left)]
            if not selected_queries:
                trace.append(
                    {
                        "round": round_number,
                        "decision": "finalize",
                        "focus": plan.get("focus", ""),
                        "queries": rejected_queries,
                    }
                )
                break

        round_results = list(rejected_queries)
        for query in selected_queries:
            total_queries += 1
            try:
                raw_result = http_json(
                    f"{cfg['lokiUrl']}/loki/api/v1/query_range",
                    params={
                        "query": query["expr"],
                        "start": str(start_ns),
                        "end": str(end_ns),
                        "limit": str(cfg["investigationMaxLinesPerQuery"]),
                        "direction": "backward",
                    },
                    timeout=int(cfg["investigationQueryTimeoutSeconds"]),
                )
                aggregated = aggregate_query_result(
                    raw_result,
                    query,
                    top_repeats=int(cfg["investigationTopRepeatsPerQuery"]),
                    sample_lines=int(cfg["investigationSampleLinesPerQuery"]),
                )
            except urllib.error.HTTPError as exc:
                body = exc.read().decode("utf-8", errors="replace")
                error_text = f"HTTP {exc.code}"
                if body:
                    error_text += f": {compact_text(body, 500)}"
                log_info(
                    "investigation query failed: title=%r expr=%r error=%s"
                    % (query["title"], query["expr"], error_text)
                )
                aggregated = build_query_error_result(query, error_text)
            except urllib.error.URLError as exc:
                error_text = f"URL error: {exc}"
                log_info(
                    "investigation query failed: title=%r expr=%r error=%s"
                    % (query["title"], query["expr"], error_text)
                )
                aggregated = build_query_error_result(query, error_text)
            round_results.append(aggregated)
        trace.append(
            {
                "round": round_number,
                "decision": "query",
                "focus": plan.get("focus", ""),
                "queries": round_results,
            }
        )

    return trace


def create_previous_snapshot(raw_text: str):
    if not raw_text.strip():
        return {"generated_at": None, "queries": [], "vm": None, "window": None}
    try:
        return json.loads(raw_text)
    except json.JSONDecodeError:
        return {"generated_at": None, "queries": [], "vm": None, "window": None}


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", required=True)
    args = parser.parse_args()

    cfg = read_json_file(args.config)

    now_ns = int(time.time() * 1_000_000_000)
    now_iso = now_utc_iso()
    run_date = now_utc_date()
    end_ns = now_ns
    start_ns = run_date_epoch(cfg["lookback"]) * 1_000_000_000
    memory_start_ns = run_date_epoch(cfg["memoryLookback"]) * 1_000_000_000
    today_start_ns = run_date_epoch(f"{run_date} 00:00:00") * 1_000_000_000

    previous_snapshot_raw = fetch_latest_digest(cfg, "snapshot", memory_start_ns, today_start_ns)
    previous_memory_raw = fetch_latest_digest(cfg, "memory", memory_start_ns, today_start_ns)

    previous_snapshot = create_previous_snapshot(previous_snapshot_raw)
    previous_memory = normalize_previous_memory_text(previous_memory_raw, run_date)

    baseline_queries = []
    for query in cfg["logQueries"]:
        raw_result = http_json(
            f"{cfg['lokiUrl']}/loki/api/v1/query_range",
            params={
                "query": query["expr"],
                "start": str(start_ns),
                "end": str(end_ns),
                "limit": str(cfg["maxLinesPer"]),
                "direction": "backward",
            },
            timeout=int(cfg["investigationQueryTimeoutSeconds"]),
        )
        baseline_queries.append(
            aggregate_query_result(
                raw_result,
                query,
                top_repeats=int(cfg["topRepeatsPerQuery"]),
                sample_lines=int(cfg["sampleLinesPerQuery"]),
            )
        )

    current_snapshot = {
        "generated_at": now_iso,
        "queries": baseline_queries,
        "vm": cfg["digestVm"],
        "window": cfg["lookback"],
    }
    prompt_snapshot = {
        "generated_at": current_snapshot["generated_at"],
        "vm": current_snapshot["vm"],
        "window": current_snapshot["window"],
        "queries": [
            {
                "expr": query["expr"],
                "title": query["title"],
                "total_lines": query["total_lines"],
                "unique_signatures": query["unique_signatures"],
                "observed_units": query["observed_units"],
                "observed_vms": query["observed_vms"],
                "priority_counts": query["priority_counts"],
                "priority_max": query.get("priority_max"),
                "repeat_groups": query["repeat_groups"][: int(cfg["topRepeatsPerQuery"])],
                "sample_lines": query["sample_lines"],
            }
            for query in current_snapshot["queries"]
        ],
    }
    diff_data = build_diff(current_snapshot, previous_snapshot, int(cfg["topRepeatsPerQuery"]))

    log_info(
        "current snapshot chars=%s prompt snapshot chars=%s previous snapshot chars=%s diff chars=%s previous memory chars=%s"
        % (
            len(json.dumps(current_snapshot, sort_keys=True)),
            len(json.dumps(prompt_snapshot, sort_keys=True)),
            len(json.dumps(previous_snapshot, sort_keys=True)),
            len(json.dumps(diff_data, sort_keys=True)),
            len(json.dumps(previous_memory, sort_keys=True)),
        )
    )
    log_info(
        "diff changed_query_count=%s initial_run=%s"
        % (diff_data["changed_query_count"], diff_data["initial_run"])
    )

    investigation_trace = build_investigation(
        cfg,
        previous_memory=previous_memory,
        snapshot=prompt_snapshot,
        diff_data=diff_data,
        start_ns=start_ns,
        end_ns=end_ns,
    )
    if investigation_trace:
        log_info(
            "investigation rounds=%s total_queries=%s"
            % (
                len(investigation_trace),
                sum(len(round_item.get("queries") or []) for round_item in investigation_trace),
            )
        )

    context_window = int(cfg["contextWindow"] or cfg["contextWindowFallback"])
    summary_max_tokens = clamp_max_tokens(context_window, int(cfg["summaryMaxTokens"]), cfg)
    memory_max_tokens = clamp_max_tokens(context_window, int(cfg["memoryMaxTokens"]), cfg)
    summary_budget = min(
        calc_prompt_char_budget(context_window, summary_max_tokens, cfg),
        int(cfg["summaryMaxPromptChars"]),
    )
    memory_budget = min(
        calc_prompt_char_budget(context_window, memory_max_tokens, cfg),
        int(cfg["memoryMaxPromptChars"]),
    )
    log_info(
        "configured llama context window=%s summary_max_tokens=%s memory_max_tokens=%s"
        % (context_window, summary_max_tokens, memory_max_tokens)
    )
    log_info(
        "summary prompt budget chars=%s memory prompt budget chars=%s"
        % (summary_budget, memory_budget)
    )

    def summary_builder(level: int):
        return build_summary_request(
            cfg,
            compact_memory(previous_memory, level),
            compact_snapshot(prompt_snapshot, level),
            compact_diff(diff_data, level),
            compact_investigation_trace(investigation_trace, level),
            summary_max_tokens,
        )

    summary_payload, summary_size, summary_level = fit_request_to_budget(summary_builder, summary_budget)
    log_info(f"summary request chars={summary_size} budget={summary_budget} compaction_level={summary_level}")
    summary_response = request_llama(cfg, summary_payload, "summary generation")
    summary_text = extract_response_content(summary_response, "summary generation")
    summary_json = normalize_summary_json_text(summary_text)
    summary_markdown = render_summary_markdown(summary_json, now_iso)

    def memory_builder(level: int):
        return build_memory_request(
            cfg,
            compact_memory(previous_memory, level),
            compact_snapshot(prompt_snapshot, level),
            compact_diff(diff_data, level),
            compact_investigation_trace(investigation_trace, level),
            summary_json,
            memory_max_tokens,
        )

    memory_payload, memory_size, memory_level = fit_request_to_budget(memory_builder, memory_budget)
    log_info(f"memory request chars={memory_size} budget={memory_budget} compaction_level={memory_level}")
    memory_response = request_llama(cfg, memory_payload, "rolling memory update")
    memory_text = extract_response_content(memory_response, "rolling memory update")
    updated_memory_body = normalize_updated_memory_text(memory_text, run_date)

    current_memory_content = json.dumps(updated_memory_body, sort_keys=True)
    previous_memory_content = json.dumps({k: v for k, v in previous_memory.items() if k != "meta"}, sort_keys=True)
    current_memory_hash = sha256_text(current_memory_content)
    previous_memory_hash = sha256_text(previous_memory_content)
    previous_unchanged_runs = int((previous_memory.get("meta") or {}).get("unchanged_runs") or 0)
    unchanged_runs = previous_unchanged_runs + 1 if current_memory_hash == previous_memory_hash else 0

    memory_output = copy.deepcopy(updated_memory_body)
    memory_output["meta"] = {
        "content_sha256": current_memory_hash,
        "previous_snapshot_generated_at": previous_snapshot.get("generated_at"),
        "source_snapshot_generated_at": now_iso,
        "unchanged_runs": unchanged_runs,
        "updated_at": now_iso,
    }
    memory_output_json = json.dumps(memory_output, indent=2, sort_keys=True) + "\n"

    log_info(
        "summary chars=%s memory chars=%s prev_memory_hash=%s current_memory_hash=%s unchanged_runs=%s"
        % (
            len(summary_markdown),
            len(memory_output_json),
            previous_memory_hash,
            current_memory_hash,
            unchanged_runs,
        )
    )
    if unchanged_runs >= int(cfg["staleMemoryWarnAfter"]):
        log_info(
            f"warning: rolling memory content has remained unchanged for {unchanged_runs} consecutive runs"
        )
    if len(memory_output_json) > int(cfg["rollingMemoryMaxChars"]):
        log_info(
            f"warning: rolling memory exceeds rollingMemoryMaxChars={cfg['rollingMemoryMaxChars']}; consider lowering prompt output size"
        )

    investigation_output = json.dumps({"generated_at": now_iso, "rounds": investigation_trace}, indent=2, sort_keys=True) + "\n"
    snapshot_output = json.dumps(current_snapshot, indent=2, sort_keys=True) + "\n"
    diff_output = json.dumps(diff_data, indent=2, sort_keys=True) + "\n"

    push_digest(cfg, now_ns, "summary", summary_markdown)
    push_digest(cfg, now_ns, "memory", memory_output_json)
    push_digest(cfg, now_ns, "snapshot", snapshot_output)
    push_digest(cfg, now_ns, "diff", diff_output)
    push_digest(cfg, now_ns, "investigation", investigation_output)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
