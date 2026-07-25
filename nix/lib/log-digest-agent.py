#!/usr/bin/env python3
"""logDigest - homelab log and metric digest.

Two phases, split on the GPU boundary:

  collect   No GPU. Deterministic Loki/Prometheus aggregates over an interval.
            Updates a persistent signature catalog and volume baseline, then
            writes an evidence pack. Cheap enough to run hourly.

  reason    GPU. A read-only tool-calling agent investigates the evidence pack,
            then a single synthesis call writes the digest. Budgeted in measured
            GPU milliseconds reported by llama-server, not wall clock.

Design notes that matter:

  * Severity is content-based, not journald PRIORITY. This fleet runs .NET/Java/Go
    services that log everything at PRIORITY 6 and put severity in the message
    text, so PRIORITY<=4 finds only firewall drops. Content matching finds a few
    hundred real events per day, which is small enough to capture exhaustively.

  * "Is this new?" is answered by the on-disk catalog, not by the model. The
    catalog holds exact first_seen/days_seen per message signature, so novelty and
    silence are facts rather than recollections.

  * The transcript is append-only. llama.cpp reuses its KV cache only when the
    prompt prefix is byte-identical, so nothing already sent is ever rebuilt.

  * Every finding must cite evidence refs that exist in the pack. Findings whose
    refs do not resolve are dropped. This is a hallucination filter that costs no
    GPU at all.
"""

import argparse
import hashlib
import json
import math
import os
import re
import statistics
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from datetime import datetime, timedelta, timezone


# --------------------------------------------------------------------------
# basics
# --------------------------------------------------------------------------

def log_info(message: str) -> None:
    print(f"logDigest: {message}", flush=True)


def utcnow() -> datetime:
    return datetime.now(timezone.utc)


def iso(dt: datetime) -> str:
    return dt.replace(microsecond=0).isoformat()


def to_ns(dt: datetime) -> int:
    return int(dt.timestamp() * 1_000_000_000)


def parse_iso(text: str):
    try:
        return datetime.fromisoformat(text)
    except (TypeError, ValueError):
        return None


def read_json(path: str, default=None):
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (FileNotFoundError, json.JSONDecodeError):
        return default


def write_json(path: str, data) -> None:
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, sort_keys=True)
        handle.write("\n")
    os.replace(tmp, path)


def write_text(path: str, content: str) -> None:
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        handle.write(content)
    os.replace(tmp, path)


def squeeze(value) -> str:
    if value is None:
        return ""
    if isinstance(value, list):
        value = "".join(str(item) for item in value)
    return " ".join(str(value).split())


def clip(text: str, limit: int) -> str:
    text = str(text)
    if limit < 4 or len(text) <= limit:
        return text
    return text[: limit - 1] + "…"


def human_count(value) -> str:
    try:
        value = float(value)
    except (TypeError, ValueError):
        return "-"
    if value >= 1_000_000:
        return f"{value / 1_000_000:.1f}M"
    if value >= 1_000:
        return f"{value / 1_000:.1f}k"
    return f"{value:.0f}"


def human_bytes(value) -> str:
    try:
        value = float(value)
    except (TypeError, ValueError):
        return "-"
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if abs(value) < 1024 or unit == "TiB":
            return f"{value:.1f}{unit}"
        value /= 1024
    return f"{value:.1f}TiB"


def render_table(headers, rows, limit: int = 0) -> str:
    """Fixed-width text table. Roughly 3x cheaper in tokens than JSON records."""
    rows = [[("" if cell is None else str(cell)) for cell in row] for row in rows]
    truncated = 0
    if limit and len(rows) > limit:
        truncated = len(rows) - limit
        rows = rows[:limit]
    if not rows:
        return "(none)"
    widths = [len(str(head)) for head in headers]
    for row in rows:
        for index, cell in enumerate(row):
            if index < len(widths):
                widths[index] = max(widths[index], len(cell))
    out = ["  ".join(str(head).ljust(widths[index]) for index, head in enumerate(headers)).rstrip()]
    for row in rows:
        out.append("  ".join(cell.ljust(widths[index]) for index, cell in enumerate(row)).rstrip())
    if truncated:
        out.append(f"... {truncated} more rows omitted")
    return "\n".join(out)


# --------------------------------------------------------------------------
# http
# --------------------------------------------------------------------------

def http_get_json(url: str, params=None, timeout: int = 60):
    if params:
        url = f"{url}?{urllib.parse.urlencode(params)}"
    request = urllib.request.Request(url, method="GET")
    request.add_header("Accept", "application/json")
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


def http_post_json(url: str, payload, timeout: int = 60):
    request = urllib.request.Request(url, method="POST")
    request.add_header("Content-Type", "application/json")
    body = json.dumps(payload).encode("utf-8")
    with urllib.request.urlopen(request, data=body, timeout=timeout) as response:
        raw = response.read().decode("utf-8")
        return json.loads(raw) if raw else None


def http_post_raw(url: str, payload, timeout: int = 60) -> None:
    request = urllib.request.Request(url, method="POST")
    request.add_header("Content-Type", "application/json")
    body = json.dumps(payload).encode("utf-8")
    with urllib.request.urlopen(request, data=body, timeout=timeout):
        return None


def describe_http_error(exc) -> str:
    if isinstance(exc, urllib.error.HTTPError):
        try:
            body = exc.read().decode("utf-8", errors="replace")
        except Exception:
            body = ""
        return clip(f"HTTP {exc.code} {squeeze(body)}", 300)
    return clip(f"{type(exc).__name__}: {exc}", 300)


# --------------------------------------------------------------------------
# loki / prometheus clients
# --------------------------------------------------------------------------

class QueryError(Exception):
    pass


class Loki:
    def __init__(self, base_url: str, timeout: int = 90):
        self.base = base_url.rstrip("/")
        self.timeout = timeout

    def instant(self, expr: str, at: datetime):
        """Metric query at a point in time -> [(labels, value)]."""
        try:
            data = http_get_json(
                f"{self.base}/loki/api/v1/query",
                {"query": expr, "time": str(to_ns(at))},
                timeout=self.timeout,
            )
        except Exception as exc:
            raise QueryError(describe_http_error(exc)) from exc
        return parse_vector(data)

    def series(self, expr: str, start: datetime, end: datetime, step: int):
        try:
            data = http_get_json(
                f"{self.base}/loki/api/v1/query_range",
                {
                    "query": expr,
                    "start": str(to_ns(start)),
                    "end": str(to_ns(end)),
                    "step": str(step),
                },
                timeout=self.timeout,
            )
        except Exception as exc:
            raise QueryError(describe_http_error(exc)) from exc
        return parse_matrix(data)

    def streams(self, expr: str, start: datetime, end: datetime, limit: int, direction: str = "backward"):
        """Log query -> [(labels, ts_ns, payload_dict, raw_line)]."""
        try:
            data = http_get_json(
                f"{self.base}/loki/api/v1/query_range",
                {
                    "query": expr,
                    "start": str(to_ns(start)),
                    "end": str(to_ns(end)),
                    "limit": str(limit),
                    "direction": direction,
                },
                timeout=self.timeout,
            )
        except Exception as exc:
            raise QueryError(describe_http_error(exc)) from exc
        out = []
        for stream in (data.get("data") or {}).get("result") or []:
            labels = stream.get("stream") or {}
            for pair in stream.get("values") or []:
                if len(pair) != 2:
                    continue
                raw_ts, line = pair
                try:
                    ts = int(raw_ts)
                except (TypeError, ValueError):
                    continue
                try:
                    payload = json.loads(line)
                    if not isinstance(payload, dict):
                        payload = {}
                except json.JSONDecodeError:
                    payload = {}
                out.append((labels, ts, payload, line))
        return out

    def label_values(self, label: str):
        try:
            data = http_get_json(
                f"{self.base}/loki/api/v1/label/{urllib.parse.quote(label)}/values",
                timeout=self.timeout,
            )
        except Exception as exc:
            raise QueryError(describe_http_error(exc)) from exc
        return sorted(data.get("data") or [])

    def labels(self):
        try:
            data = http_get_json(f"{self.base}/loki/api/v1/labels", timeout=self.timeout)
        except Exception as exc:
            raise QueryError(describe_http_error(exc)) from exc
        return sorted(data.get("data") or [])

    def push(self, stream_labels: dict, ts_ns: int, content: str) -> None:
        http_post_raw(
            f"{self.base}/loki/api/v1/push",
            {"streams": [{"stream": stream_labels, "values": [[str(ts_ns), content]]}]},
            timeout=30,
        )


class Prometheus:
    def __init__(self, base_url: str, timeout: int = 60):
        self.base = base_url.rstrip("/")
        self.timeout = timeout

    def instant(self, expr: str, at: datetime):
        try:
            data = http_get_json(
                f"{self.base}/api/v1/query",
                {"query": expr, "time": f"{at.timestamp():.3f}"},
                timeout=self.timeout,
            )
        except Exception as exc:
            raise QueryError(describe_http_error(exc)) from exc
        return parse_vector(data)

    def series(self, expr: str, start: datetime, end: datetime, step: int):
        try:
            data = http_get_json(
                f"{self.base}/api/v1/query_range",
                {
                    "query": expr,
                    "start": f"{start.timestamp():.3f}",
                    "end": f"{end.timestamp():.3f}",
                    "step": str(step),
                },
                timeout=self.timeout,
            )
        except Exception as exc:
            raise QueryError(describe_http_error(exc)) from exc
        return parse_matrix(data)


def parse_vector(data):
    if data.get("status") != "success":
        raise QueryError(clip(str(data.get("error") or data), 300))
    payload = data.get("data") or {}
    kind = payload.get("resultType")
    out = []
    if kind == "vector":
        for item in payload.get("result") or []:
            value = item.get("value") or [None, None]
            out.append((item.get("metric") or {}, safe_float(value[1])))
    elif kind == "matrix":
        for item in payload.get("result") or []:
            values = item.get("values") or []
            if values:
                out.append((item.get("metric") or {}, safe_float(values[-1][1])))
    elif kind == "scalar":
        out.append(({}, safe_float((payload.get("result") or [None, None])[1])))
    elif kind == "streams":
        raise QueryError("expected a metric query but got a log query; wrap it in a metric function")
    return out


def parse_matrix(data):
    if data.get("status") != "success":
        raise QueryError(clip(str(data.get("error") or data), 300))
    payload = data.get("data") or {}
    if payload.get("resultType") == "streams":
        raise QueryError("expected a metric query but got a log query; wrap it in a metric function")
    out = []
    for item in payload.get("result") or []:
        points = []
        for pair in item.get("values") or []:
            if len(pair) == 2:
                points.append((safe_float(pair[0]), safe_float(pair[1])))
        out.append((item.get("metric") or {}, points))
    return out


def safe_float(value):
    try:
        result = float(value)
    except (TypeError, ValueError):
        return None
    if math.isnan(result) or math.isinf(result):
        return None
    return result


def label_key(labels: dict, keys) -> str:
    return "/".join(str(labels.get(key, "-")) for key in keys)


# --------------------------------------------------------------------------
# message signatures
# --------------------------------------------------------------------------

# Colour codes must go before anything else. Left in place, sequences like ESC[2m
# get read as "2 minutes" by the quantity rule and the signature turns to noise.
ANSI_ESCAPE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b[@-Z\\-_]")

# Order matters: the specific patterns must run before the generic number rule,
# otherwise timestamps and addresses get shredded into <n> soup and every line
# collapses into the same useless signature.
SIGNATURE_RULES = [
    (re.compile(r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:[.,]\d+)?(?:Z|[+-]\d{2}:?\d{2})?"), "<ts>"),
    (re.compile(r"\b[A-Z][a-z]{2}\s+\d{1,2}\s+\d{2}:\d{2}:\d{2}\b"), "<ts>"),
    (re.compile(r"\b\d{2}:\d{2}:\d{2}(?:[.,]\d+)?\b"), "<time>"),
    (re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"), "<uuid>"),
    (re.compile(r"\b[0-9a-fA-F]{2}(?::[0-9a-fA-F]{2}){5}\b"), "<mac>"),
    (re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b"), "<ip>"),
    (re.compile(r"\b(?:[0-9a-fA-F]{1,4}:){4,7}[0-9a-fA-F]{1,4}\b"), "<ip6>"),
    (re.compile(r"\b0x[0-9a-fA-F]+\b"), "<hex>"),
    (re.compile(r"\b[0-9a-fA-F]{12,}\b"), "<hex>"),
    (re.compile(r"/(?:[\w.@%+~-]+/){2,}[\w.@%+~-]*"), "<path>"),
    (re.compile(r"\b\d+(?:\.\d+)?\s?(?:ns|us|ms|s|m|h|d|B|KB|MB|GB|TB|KiB|MiB|GiB|TiB|%)\b"), "<qty>"),
    (re.compile(r"\b\d[\d_,]*(?:\.\d+)?\b"), "<n>"),
]

SEVERITY_RULES = [
    ("critical", re.compile(r"(?i)\b(fatal|panic|emerg|critical|corrupt\w*|data loss)\b")),
    ("error", re.compile(r"(?i)\b(error|exception|traceback|failed|failure|refused|denied|unreachable|timed?[ -]?out|timeout)\b")),
    ("warn", re.compile(r"(?i)\b(warn|warning|retry|retrying|degraded|throttl\w+|deprecated)\b")),
]

# Matched against the signature, not the raw line, so it survives normalization.
SEVERITY_EXCLUDE = re.compile(
    r"(?i)\b(no error|without error|0 error|error[_-]?count|errors?=0|"
    r"error[_-]?rate|iferror|onerror|error[_-]?handler|errorlog|error_log)\b"
)


def signature_of(message: str) -> str:
    text = squeeze(ANSI_ESCAPE.sub("", message or ""))
    for pattern, placeholder in SIGNATURE_RULES:
        text = pattern.sub(placeholder, text)
    return clip(squeeze(text), 220)


def severity_of(message: str, priority) -> str:
    """Content-first severity.

    journald PRIORITY is nearly useless on this fleet - the media stack logs
    everything at 6 and writes severity into the message - so the message text is
    the primary signal and PRIORITY only escalates.
    """
    text = squeeze(ANSI_ESCAPE.sub("", message or ""))
    level = "info"
    if not SEVERITY_EXCLUDE.search(text):
        for name, pattern in SEVERITY_RULES:
            if pattern.search(text):
                level = name
                break
    # An explicit DEBUG/TRACE marker is unambiguous: whatever keyword appeared,
    # the emitting service did not consider this worth an operator's attention.
    if level in ("error", "warn") and re.search(r"(?i)\b(debug|trace)\b", text[:60]):
        level = "info"
    try:
        priority_num = int(priority)
    except (TypeError, ValueError):
        priority_num = None
    if priority_num is not None:
        if priority_num <= 2:
            level = "critical"
        elif priority_num == 3 and level in ("info", "warn"):
            level = "error"
        elif priority_num == 4 and level == "info":
            level = "warn"
    return level


SEVERITY_ORDER = {"critical": 0, "error": 1, "warn": 2, "info": 3}


def message_of(payload: dict, raw_line: str) -> str:
    # Colour codes are stripped at the single point every consumer goes through,
    # so signatures, severity, stored examples and tool output are all clean.
    for key in ("MESSAGE", "message", "msg"):
        if payload.get(key):
            return squeeze(ANSI_ESCAPE.sub("", str(payload[key])))
    return squeeze(ANSI_ESCAPE.sub("", raw_line or ""))


def unit_of(labels: dict, payload: dict) -> str:
    for source in (labels, payload):
        for key in ("unit", "_SYSTEMD_UNIT", "SYSLOG_IDENTIFIER", "service"):
            value = squeeze(source.get(key))
            if value and value != "-":
                return value
    return "-"


def signature_id(vm: str, service: str, signature: str) -> str:
    # Separator that cannot occur in a label value or a normalized signature, so
    # distinct (vm, service, signature) triples cannot collide into one id.
    raw = "\x1f".join([vm, service, signature])
    return "sig:" + hashlib.sha1(raw.encode("utf-8")).hexdigest()[:10]


# --------------------------------------------------------------------------
# robust statistics
# --------------------------------------------------------------------------

def median_mad(values):
    """Median and median absolute deviation.

    Log volumes are heavy-tailed and bursty, so mean/stddev reports half the fleet
    as anomalous every day. MAD does not.
    """
    clean = [value for value in values if value is not None]
    if not clean:
        return None, None
    med = statistics.median(clean)
    mad = statistics.median([abs(value - med) for value in clean])
    return med, mad


def robust_z(current, values):
    med, mad = median_mad(values)
    if med is None or current is None:
        return None
    if mad is None or mad < 1e-9:
        # No spread in the baseline: only a real move off the median counts.
        if abs(current - med) < max(3.0, med * 0.5):
            return 0.0
        return 6.0 if current > med else -6.0
    return 0.6745 * (current - med) / mad


# --------------------------------------------------------------------------
# catalog - the deterministic memory of what is normal
# --------------------------------------------------------------------------

class Catalog:
    """Persistent per-signature history.

    This is what lets the digest say "first time ever" or "logged every day for
    three weeks and went silent today" as a fact rather than a guess. The previous
    design asked the model to remember this across runs, which it could not.
    """

    def __init__(self, data=None):
        data = data or {}
        self.signatures = data.get("signatures") or {}
        self.updated_at = data.get("updated_at")
        self.started_at = data.get("started_at")

    @classmethod
    def load(cls, path: str):
        return cls(read_json(path, default={}))

    def save(self, path: str, now: datetime) -> None:
        write_json(
            path,
            {
                "signatures": self.signatures,
                "updated_at": iso(now),
                "started_at": self.started_at or iso(now),
            },
        )

    def maturity_days(self, now: datetime) -> float:
        """How long this catalog has been accumulating.

        On a fresh catalog every signature is trivially "first seen today", which
        would bury the digest in meaningless novelty. Callers use this to suppress
        novelty claims until there is something to be novel against.
        """
        start = parse_iso(self.started_at or "")
        if start is None:
            return 0.0
        return (now - start).total_seconds() / 86400.0

    def observe(self, sig_id: str, *, vm, service, unit, severity, signature, example, count, day: str, now: datetime):
        entry = self.signatures.get(sig_id)
        if entry is None:
            entry = {
                "vm": vm,
                "service": service,
                "unit": unit,
                "severity": severity,
                "signature": signature,
                "example": clip(example, 400),
                "first_seen": iso(now),
                "last_seen": iso(now),
                "total": 0,
                "days": {},
            }
            self.signatures[sig_id] = entry
        entry["last_seen"] = iso(now)
        entry["total"] = int(entry.get("total", 0)) + int(count)
        entry["unit"] = unit or entry.get("unit")
        entry["example"] = clip(example, 400) or entry.get("example")
        if SEVERITY_ORDER.get(severity, 3) < SEVERITY_ORDER.get(entry.get("severity", "info"), 3):
            entry["severity"] = severity
        days = entry.setdefault("days", {})
        days[day] = int(days.get(day, 0)) + int(count)

    def prune(self, now: datetime, keep_days: int, max_entries: int) -> int:
        cutoff = now - timedelta(days=keep_days)
        removed = 0
        for sig_id in list(self.signatures):
            entry = self.signatures[sig_id]
            last = parse_iso(entry.get("last_seen") or "")
            if last is None or last < cutoff:
                del self.signatures[sig_id]
                removed += 1
                continue
            days = entry.get("days") or {}
            keep = {}
            for day, count in days.items():
                stamp = parse_iso(day + "T00:00:00+00:00")
                if stamp is not None and stamp >= cutoff - timedelta(days=1):
                    keep[day] = count
            entry["days"] = keep
        if len(self.signatures) > max_entries:
            ranked = sorted(
                self.signatures.items(),
                key=lambda item: (
                    SEVERITY_ORDER.get(item[1].get("severity", "info"), 3),
                    -int(item[1].get("total", 0)),
                ),
            )
            for sig_id, _ in ranked[max_entries:]:
                del self.signatures[sig_id]
                removed += 1
        return removed

    def days_seen(self, sig_id: str) -> int:
        return len((self.signatures.get(sig_id) or {}).get("days") or {})

    def age_days(self, sig_id: str, now: datetime):
        first = parse_iso((self.signatures.get(sig_id) or {}).get("first_seen") or "")
        if first is None:
            return None
        return (now - first).total_seconds() / 86400.0


# --------------------------------------------------------------------------
# collect phase
# --------------------------------------------------------------------------

def noise_matcher(cfg):
    # fullmatch, because Loki anchors !~ regexes. Matching differently here would
    # let a service be excluded server-side but still cataloged locally.
    patterns = [re.compile(pattern) for pattern in cfg.get("noiseServices") or []]

    def is_noise(service: str) -> bool:
        return any(pattern.fullmatch(service or "") for pattern in patterns)

    return is_noise


def selector_excluding_noise(cfg) -> str:
    noisy = cfg.get("noiseServices") or []
    if not noisy:
        return '{vm=~".+"}'
    joined = "|".join(noisy)
    return '{vm=~".+", service!~"%s"}' % joined


def collect(cfg, args) -> int:
    now = utcnow()
    state_dir = cfg["stateDir"]
    os.makedirs(state_dir, exist_ok=True)

    loki = Loki(cfg["lokiUrl"], timeout=int(cfg["queryTimeoutSeconds"]))
    prom = Prometheus(cfg["prometheusUrl"], timeout=int(cfg["queryTimeoutSeconds"]))

    interval_seconds = int(cfg["collectIntervalSeconds"])
    window_start = now - timedelta(seconds=interval_seconds)
    day = now.strftime("%Y-%m-%d")
    warnings = []

    def guard(label, fn, default):
        try:
            return fn()
        except QueryError as exc:
            warnings.append(f"{label}: {exc}")
            log_info(f"warning: {label} failed: {exc}")
            return default

    # -- volume, exactly, no sampling ------------------------------------
    volume = guard(
        "volume",
        lambda: loki.instant(
            'sum by (vm, service) (count_over_time({vm=~".+"}[%ds]))' % interval_seconds, now
        ),
        [],
    )
    volume_by_pair = {label_key(labels, ("vm", "service")): value for labels, value in volume}

    # -- severity events, captured exhaustively --------------------------
    is_noise = noise_matcher(cfg)
    severity_expr = "%s |~ `%s`" % (selector_excluding_noise(cfg), cfg["severityRegex"])
    severity_lines = guard(
        "severity",
        lambda: loki.streams(
            severity_expr, window_start, now, int(cfg["severityMaxLines"]), "backward"
        ),
        [],
    )
    if len(severity_lines) >= int(cfg["severityMaxLines"]):
        warnings.append(
            f"severity capture hit the {cfg['severityMaxLines']}-line cap; counts are a floor, not a total"
        )

    catalog_path = os.path.join(state_dir, "catalog.json")
    catalog = Catalog.load(catalog_path)

    grouped = defaultdict(lambda: {"count": 0, "example": "", "severity": "info", "unit": "-"})
    for labels, _ts, payload, raw in severity_lines:
        vm = squeeze(labels.get("vm") or payload.get("vm") or "-")
        service = squeeze(labels.get("service") or payload.get("service") or "-")
        if is_noise(service):
            continue
        message = message_of(payload, raw)
        if not message:
            continue
        severity = severity_of(message, payload.get("PRIORITY"))
        if severity == "info":
            continue
        signature = signature_of(message)
        sig_id = signature_id(vm, service, signature)
        bucket = grouped[sig_id]
        bucket["count"] += 1
        bucket["vm"] = vm
        bucket["service"] = service
        bucket["signature"] = signature
        bucket["unit"] = unit_of(labels, payload)
        if not bucket["example"]:
            bucket["example"] = clip(message, 400)
        if SEVERITY_ORDER.get(severity, 3) < SEVERITY_ORDER.get(bucket["severity"], 3):
            bucket["severity"] = severity

    for sig_id, bucket in grouped.items():
        catalog.observe(
            sig_id,
            vm=bucket.get("vm", "-"),
            service=bucket.get("service", "-"),
            unit=bucket.get("unit", "-"),
            severity=bucket.get("severity", "info"),
            signature=bucket.get("signature", ""),
            example=bucket.get("example", ""),
            count=bucket["count"],
            day=day,
            now=now,
        )

    removed = catalog.prune(now, int(cfg["baselineDays"]) + 1, int(cfg["catalogMaxEntries"]))
    catalog.save(catalog_path, now)

    # -- point-in-time facts worth having a history of --------------------
    # Only what the evidence pack cannot recover later. Disk and memory are read
    # at pack time straight from Prometheus, which keeps its own history, so
    # sampling them here would be pure duplication. A unit that failed and
    # recovered between runs, however, is invisible to any later query.
    failed_now = guard(
        "failed_units",
        lambda: prom.instant('node_systemd_unit_state{state="failed"} == 1', now),
        [],
    )
    boot_times = guard("boot_time", lambda: prom.instant("node_boot_time_seconds", now), [])
    scrape_up = guard("scrape_up", lambda: prom.instant('up{job="node"}', now), [])

    record = {
        "at": iso(now),
        "day": day,
        "interval_seconds": interval_seconds,
        "volume": volume_by_pair,
        "severity_counts": {sig_id: bucket["count"] for sig_id, bucket in grouped.items()},
        "failed_units": sorted(
            "%s|%s" % (labels.get("vm") or labels.get("instance", "-"), labels.get("name", "-"))
            for labels, _ in failed_now
        ),
        "boot_time": {label_key(labels, ("instance",)): value for labels, value in boot_times},
        "scrape_up": {label_key(labels, ("vm", "instance")): value for labels, value in scrape_up},
        "warnings": warnings,
    }

    baseline_path = os.path.join(state_dir, "baseline.jsonl")
    append_baseline(baseline_path, record, now, int(cfg["baselineDays"]))

    log_info(
        "collect: window=%ds streams=%d severity_lines=%d signatures=%d catalog=%d pruned=%d warnings=%d"
        % (
            interval_seconds,
            len(volume_by_pair),
            len(severity_lines),
            len(grouped),
            len(catalog.signatures),
            removed,
            len(warnings),
        )
    )

    if args.build_pack or cfg.get("alwaysBuildPack"):
        pack = build_evidence_pack(cfg, loki, prom, catalog, now)
        pack_path = os.path.join(state_dir, "evidence.json")
        write_json(pack_path, pack)
        write_json(os.path.join(state_dir, f"evidence-{day}.json"), pack)
        log_info(f"collect: wrote evidence pack to {pack_path}")
    return 0


def append_baseline(path: str, record, now: datetime, keep_days: int) -> None:
    cutoff = now - timedelta(days=keep_days)
    rows = []
    try:
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    parsed = json.loads(line)
                except json.JSONDecodeError:
                    continue
                stamp = parse_iso(parsed.get("at") or "")
                if stamp is not None and stamp >= cutoff:
                    rows.append(parsed)
    except FileNotFoundError:
        pass
    rows.append(record)
    tmp = f"{path}.tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, sort_keys=True) + "\n")
    os.replace(tmp, path)


def load_baseline(path: str, now: datetime, days: int):
    cutoff = now - timedelta(days=days)
    rows = []
    try:
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                try:
                    parsed = json.loads(line)
                except json.JSONDecodeError:
                    continue
                stamp = parse_iso(parsed.get("at") or "")
                if stamp is not None and stamp >= cutoff:
                    rows.append(parsed)
    except FileNotFoundError:
        pass
    return rows


# --------------------------------------------------------------------------
# evidence pack
# --------------------------------------------------------------------------

def rolling_windows(baseline, now: datetime, days: int, min_coverage: int):
    """Bucket collector records into 24h windows ending at `now`.

    Calendar days are the wrong unit here: the digest runs at 03:30 local, so a
    UTC-day bucket would hold one or two hours of data and every signature would
    look like it had collapsed. Windows are anchored to the run instead.

    Windows with too few collector records are dropped rather than compared
    against, so a stretch where the collector was down cannot masquerade as a
    fleet-wide anomaly.
    """
    current = {"volume": defaultdict(float), "signatures": defaultdict(float), "records": 0,
               "failed_units": set()}
    priors = [
        {"volume": defaultdict(float), "signatures": defaultdict(float), "records": 0,
         "failed_units": set()}
        for _ in range(days)
    ]

    for row in baseline:
        at = parse_iso(row.get("at") or "")
        if at is None:
            continue
        age_hours = (now - at).total_seconds() / 3600.0
        if age_hours < 0:
            continue
        bucket = int(age_hours // 24)
        if bucket == 0:
            target = current
        elif 1 <= bucket <= days:
            target = priors[bucket - 1]
        else:
            continue
        target["records"] += 1
        for key, value in (row.get("volume") or {}).items():
            target["volume"][key] += float(value or 0)
        for key, value in (row.get("severity_counts") or {}).items():
            target["signatures"][key] += float(value or 0)
        for item in row.get("failed_units") or []:
            target["failed_units"].add(item)

    usable = [window for window in priors if window["records"] >= min_coverage]
    return current, usable


def build_evidence_pack(cfg, loki, prom, catalog, now: datetime):
    """Everything the model should not have to discover for itself.

    Anything computable in Python is computed here, with the GPU cold. The model's
    job is judgement about what matters, not arithmetic on log counts.
    """
    state_dir = cfg["stateDir"]
    window_start = now - timedelta(hours=24)
    baseline_days = int(cfg["baselineDays"])
    z_threshold = float(cfg["anomalyZThreshold"])
    warnings = []
    refs = {}
    is_noise = noise_matcher(cfg)

    def guard(label, fn, default):
        try:
            return fn()
        except QueryError as exc:
            warnings.append(f"{label}: {exc}")
            log_info(f"warning: {label} failed: {exc}")
            return default

    # -- 24h volume, exact, straight from Loki ---------------------------
    volume = guard(
        "volume_24h",
        lambda: loki.instant(
            'sum by (vm, service) (count_over_time({vm=~".+"}[24h]))', now
        ),
        [],
    )
    volume_rows = sorted(
        (
            (labels.get("vm", "-"), labels.get("service", "-"), int(value or 0))
            for labels, value in volume
        ),
        key=lambda row: -row[2],
    )
    total_lines = sum(row[2] for row in volume_rows)

    baseline = load_baseline(os.path.join(state_dir, "baseline.jsonl"), now, baseline_days + 1)
    # A window counts as usable only if the collector actually covered most of it,
    # derived from the configured interval rather than assuming hourly runs.
    expected_per_window = max(1, 86400 // max(1, int(cfg["collectIntervalSeconds"])))
    current_window, prior_windows = rolling_windows(
        baseline, now, baseline_days, min_coverage=max(1, int(expected_per_window * 0.8))
    )
    enough_history = len(prior_windows) >= 3
    if not enough_history:
        warnings.append(
            f"only {len(prior_windows)} complete 24h baseline window(s) available; "
            "anomaly and silence detection are disabled until the baseline fills"
        )

    # On a young catalog everything is trivially new, which would drown the digest
    # in novelty that means nothing.
    catalog_age = catalog.maturity_days(now)
    novelty_ready = catalog_age >= 1.5
    if not novelty_ready:
        warnings.append(
            f"signature catalog is only {catalog_age:.1f} days old; "
            "novelty detection is suppressed until it matures"
        )

    # Volume anomalies are computed entirely from collector records, so today and
    # its history come from the same measurement path and cannot drift apart.
    volume_anomalies = []
    if enough_history:
        for vm, service, exact_count in volume_rows:
            pair = f"{vm}/{service}"
            if is_noise(service):
                continue
            history = [window["volume"].get(pair, 0.0) for window in prior_windows]
            observed = current_window["volume"].get(pair, 0.0)
            score = robust_z(observed, history)
            if score is None or abs(score) < z_threshold:
                continue
            med, _ = median_mad(history)
            ref = f"vol:{vm}:{service}"
            refs[ref] = {
                "kind": "volume_anomaly",
                "vm": vm,
                "service": service,
                "today": exact_count,
                "median": round(med or 0),
                "z": round(score, 1),
                "query": 'sum(count_over_time({vm="%s", service="%s"}[1h]))' % (vm, service),
            }
            volume_anomalies.append((ref, vm, service, exact_count, round(med or 0), round(score, 1)))
        volume_anomalies.sort(key=lambda row: -abs(row[5]))

    # -- signature classification ----------------------------------------
    new_signatures = []
    escalating = []
    went_silent = []
    persistent = []

    for sig_id, entry in catalog.signatures.items():
        observed = int(current_window["signatures"].get(sig_id, 0))
        history = [window["signatures"].get(sig_id, 0.0) for window in prior_windows]
        age = catalog.age_days(sig_id, now)
        seen_days = len(entry.get("days") or {})
        severity = entry.get("severity", "info")
        common = {
            "kind": "signature",
            "vm": entry.get("vm"),
            "service": entry.get("service"),
            "unit": entry.get("unit"),
            "severity": severity,
            "signature": entry.get("signature"),
            "example": entry.get("example"),
            "first_seen": entry.get("first_seen"),
            "last_seen": entry.get("last_seen"),
            "days_seen": seen_days,
            "today": observed,
            "total": entry.get("total"),
            "query": 'sum(count_over_time({vm="%s", service="%s"}[1h]))'
            % (entry.get("vm"), entry.get("service")),
        }

        # New: first appeared inside this window. Grounded in first_seen, which is
        # independent of window bucketing.
        if novelty_ready and observed > 0 and age is not None and age <= 1.0:
            refs[sig_id] = dict(common, classification="new")
            new_signatures.append((sig_id, severity, entry, observed))
            continue

        if observed > 0 and enough_history:
            score = robust_z(observed, history)
            med, _ = median_mad(history)
            if score is not None and score >= z_threshold and observed >= 5:
                refs[sig_id] = dict(
                    common, classification="escalating", median=round(med or 0), z=round(score, 1)
                )
                escalating.append((sig_id, severity, entry, observed, round(med or 0), round(score, 1)))
                continue

        # Silence only counts when the signature was previously reliable: present
        # in most windows, at a level well above noise.
        if observed == 0 and enough_history:
            present = [value for value in history if value > 0]
            med, _ = median_mad(history)
            if len(present) >= max(3, int(len(history) * 0.8)) and med and med >= 3:
                refs[sig_id] = dict(common, classification="silent", median=round(med))
                went_silent.append((sig_id, severity, entry, round(med), len(present)))
                continue

        if observed > 0 and severity in ("critical", "error"):
            refs[sig_id] = dict(common, classification="ongoing")
            persistent.append((sig_id, severity, entry, observed, seen_days))

    def by_severity(rows, count_index):
        return sorted(
            rows,
            key=lambda row: (SEVERITY_ORDER.get(row[1], 3), -int(row[count_index] or 0)),
        )

    new_signatures = by_severity(new_signatures, 3)
    escalating = by_severity(escalating, 3)
    persistent = by_severity(persistent, 3)
    went_silent = sorted(went_silent, key=lambda row: -(row[3] or 0))

    # -- host health -----------------------------------------------------
    failed_units = guard(
        "failed_units",
        lambda: prom.instant('node_systemd_unit_state{state="failed"} == 1', now),
        [],
    )
    failed_rows = []
    currently_failed = set()
    for labels, _ in failed_units:
        vm = labels.get("vm") or labels.get("instance", "-")
        name = labels.get("name", "-")
        currently_failed.add(f"{vm}|{name}")
        ref = f"unit:{vm}:{name}"
        refs[ref] = {
            "kind": "failed_unit",
            "vm": vm,
            "unit": name,
            "state": "failed now",
            "query": 'node_systemd_unit_state{name="%s",state="failed"}' % name,
        }
        failed_rows.append((ref, vm, name, "failed now"))

    # A unit that failed at 14:00 and was restarted is invisible to an instant
    # query at 03:30, but it is exactly the kind of thing worth knowing about.
    # The hourly collector records catch it.
    for item in sorted(current_window["failed_units"]):
        vm, _, name = item.partition("|")
        if not name or item in currently_failed:
            continue
        ref = f"unit:{vm}:{name}"
        refs[ref] = {
            "kind": "failed_unit",
            "vm": vm,
            "unit": name,
            "state": "failed earlier, recovered",
            "query": 'node_systemd_unit_state{name="%s",state="failed"}' % name,
        }
        failed_rows.append((ref, vm, name, "failed earlier, recovered"))

    disk_rows = build_disk_rows(prom, now, refs, guard)
    mem_rows = build_memory_rows(prom, now, refs, guard)
    reboot_rows = build_reboot_rows(prom, now, refs, guard, baseline)
    scrape_rows = build_scrape_rows(prom, now, refs, guard)

    # -- noise, acknowledged but never narrated ---------------------------
    noise_rows = [(vm, service, count) for vm, service, count in volume_rows if is_noise(service)]

    pack = {
        "generated_at": iso(now),
        "window": {"start": iso(window_start), "end": iso(now), "hours": 24},
        "digest_vm": cfg["digestVm"],
        "topology": cfg.get("topology") or {},
        "baseline": {
            "samples": len(baseline),
            "days_available": round(
                len({row.get("day") for row in baseline if row.get("day")}), 1
            ),
            "days_configured": baseline_days,
            "z_threshold": z_threshold,
        },
        "totals": {
            "lines_24h": total_lines,
            "services": len({row[1] for row in volume_rows}),
            "vms": len({row[0] for row in volume_rows}),
            "catalog_signatures": len(catalog.signatures),
        },
        "volume": [
            {"vm": vm, "service": service, "lines": count} for vm, service, count in volume_rows
        ],
        "volume_anomalies": [
            {
                "ref": ref,
                "vm": vm,
                "service": service,
                "today": count,
                "median": med,
                "z": score,
            }
            for ref, vm, service, count, med, score in volume_anomalies
        ],
        "new_signatures": [pack_signature(sig_id, entry, count) for sig_id, _, entry, count in new_signatures],
        "escalating": [
            dict(pack_signature(sig_id, entry, count), median=med, z=score)
            for sig_id, _, entry, count, med, score in escalating
        ],
        "ongoing": [pack_signature(sig_id, entry, count) for sig_id, _, entry, count, _ in persistent],
        "went_silent": [
            dict(pack_signature(sig_id, entry, 0), median=med, days_of_history=days)
            for sig_id, _, entry, med, days in went_silent
        ],
        "failed_units": [
            {"ref": ref, "vm": vm, "unit": unit, "state": state}
            for ref, vm, unit, state in failed_rows
        ],
        "disk": disk_rows,
        "memory": mem_rows,
        "reboots": reboot_rows,
        "scrape_problems": scrape_rows,
        "suppressed_noise": [
            {"vm": vm, "service": service, "lines": count} for vm, service, count in noise_rows
        ],
        "refs": refs,
        "warnings": warnings,
    }
    return pack


def pack_signature(sig_id: str, entry, today_count):
    return {
        "ref": sig_id,
        "vm": entry.get("vm"),
        "service": entry.get("service"),
        "unit": entry.get("unit"),
        "severity": entry.get("severity"),
        "today": today_count,
        "days_seen": len(entry.get("days") or {}),
        "first_seen": entry.get("first_seen"),
        "last_seen": entry.get("last_seen"),
        "signature": entry.get("signature"),
        "example": entry.get("example"),
    }


# The Nix store is read-only and cannot fill, so it is pure noise here.
FILESYSTEM_SELECTOR = (
    'node_filesystem_%s_bytes{fstype!~"tmpfs|overlay|squashfs|ramfs",device!="ro-store"}'
)


def build_disk_rows(prom, now, refs, guard):
    avail = guard("disk_avail", lambda: prom.instant(FILESYSTEM_SELECTOR % "avail", now), [])
    size = guard("disk_size", lambda: prom.instant(FILESYSTEM_SELECTOR % "size", now), [])
    # 24h, not 6h. Measured on this fleet, a 6h window reads Loki compaction and
    # Prometheus WAL churn as a trend and reports 4.8 days to full on a
    # half-empty 466 GiB volume; the same filesystem reads 48 days over 24h.
    trend = guard(
        "disk_trend",
        lambda: prom.instant("deriv(%s[24h])" % (FILESYSTEM_SELECTOR % "avail"), now),
        [],
    )

    def index(rows):
        return {label_key(labels, ("vm", "instance", "mountpoint")): value for labels, value in rows}

    size_by = index(size)
    trend_by = index(trend)

    # Every service state directory is a bind mount of the same underlying
    # volume, so node_exporter reports one filesystem a dozen times. Collapse by
    # (vm, device) and keep the shortest mountpoint as the representative.
    by_device = {}
    for labels, available in avail:
        key = label_key(labels, ("vm", "instance", "mountpoint"))
        vm = labels.get("vm") or labels.get("instance", "-")
        device = labels.get("device", "-")
        mount = labels.get("mountpoint", "-")
        group = (vm, device)
        candidate = {
            "vm": vm,
            "device": device,
            "mount": mount,
            "avail": available,
            "size": size_by.get(key),
            "slope": trend_by.get(key),
            "mounts": 1,
        }
        existing = by_device.get(group)
        if existing is None:
            by_device[group] = candidate
        else:
            existing["mounts"] += 1
            if len(mount) < len(existing["mount"]):
                existing.update({k: candidate[k] for k in ("mount", "avail", "size", "slope")})

    rows = []
    for (vm, device), item in by_device.items():
        available, total, slope = item["avail"], item["size"], item["slope"]
        pct_used = None
        if total and available is not None and total > 0:
            pct_used = 100.0 * (1.0 - available / total)
        days_left = None
        if slope is not None and slope < -1 and available:
            days_left = available / (-slope * 86400.0)

        # A projection on a mostly-empty volume is extrapolated noise, not a
        # forecast. Only claim a horizon once the filesystem is actually filling.
        if pct_used is None or pct_used < 60:
            days_left = None

        interesting = (pct_used is not None and pct_used >= 80) or (
            days_left is not None and days_left < 30
        )
        if not interesting:
            continue

        mount = item["mount"]
        ref = f"disk:{vm}:{mount}"
        refs[ref] = {
            "kind": "disk",
            "vm": vm,
            "device": device,
            "mountpoint": mount,
            "avail_bytes": available,
            "size_bytes": total,
            "pct_used": pct_used,
            "days_to_full": days_left,
            "shared_mounts": item["mounts"],
            "query": 'node_filesystem_avail_bytes{vm="%s",mountpoint="%s"}' % (vm, mount),
        }
        rows.append(
            {
                "ref": ref,
                "vm": vm,
                "mountpoint": mount,
                "avail": human_bytes(available),
                "pct_used": None if pct_used is None else round(pct_used, 1),
                "days_to_full": None if days_left is None else round(days_left, 1),
                "shared_mounts": item["mounts"],
            }
        )
    rows.sort(key=lambda row: (row["days_to_full"] is None, row["days_to_full"] or 1e9))
    return rows


def build_memory_rows(prom, now, refs, guard):
    available = guard("mem_available", lambda: prom.instant("node_memory_MemAvailable_bytes", now), [])
    total = guard("mem_total", lambda: prom.instant("node_memory_MemTotal_bytes", now), [])
    total_by = {label_key(labels, ("vm", "instance")): value for labels, value in total}
    rows = []
    for labels, avail_value in available:
        key = label_key(labels, ("vm", "instance"))
        vm = labels.get("vm") or labels.get("instance", "-")
        total_value = total_by.get(key)
        if not total_value or avail_value is None:
            continue
        pct_used = 100.0 * (1.0 - avail_value / total_value)
        if pct_used < 85:
            continue
        ref = f"mem:{vm}"
        refs[ref] = {
            "kind": "memory",
            "vm": vm,
            "pct_used": pct_used,
            "avail_bytes": avail_value,
            "query": "node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes",
        }
        rows.append({"ref": ref, "vm": vm, "pct_used": round(pct_used, 1), "avail": human_bytes(avail_value)})
    rows.sort(key=lambda row: -row["pct_used"])
    return rows


def build_reboot_rows(prom, now, refs, guard, baseline):
    boot = guard("boot_time", lambda: prom.instant("node_boot_time_seconds", now), [])
    # Compare against the OLDEST record in the window, so a reboot anywhere inside
    # it is caught. Comparing against the newest would only ever see the last hour.
    previous = {}
    for row in baseline:
        for key, value in (row.get("boot_time") or {}).items():
            previous.setdefault(key, value)
    rows = []
    for labels, value in boot:
        key = label_key(labels, ("instance",))
        vm = labels.get("vm") or labels.get("instance", "-")
        if value is None:
            continue
        uptime_hours = (now.timestamp() - value) / 3600.0
        was = previous.get(key)
        rebooted = was is not None and abs(was - value) > 60
        if uptime_hours <= 24 or rebooted:
            ref = f"boot:{vm}"
            refs[ref] = {"kind": "reboot", "vm": vm, "uptime_hours": uptime_hours}
            rows.append({"ref": ref, "vm": vm, "uptime_hours": round(uptime_hours, 1)})
    rows.sort(key=lambda row: row["uptime_hours"])
    return rows


def build_scrape_rows(prom, now, refs, guard):
    up = guard("scrape_up", lambda: prom.instant('up{job="node"}', now), [])
    rows = []
    for labels, value in up:
        if value is None or value >= 1:
            continue
        vm = labels.get("vm") or labels.get("instance", "-")
        ref = f"scrape:{vm}"
        refs[ref] = {"kind": "scrape_down", "vm": vm}
        rows.append({"ref": ref, "vm": vm})
    return rows


# --------------------------------------------------------------------------
# pack rendering
# --------------------------------------------------------------------------

def render_pack(pack, cfg) -> str:
    """The pack as compact text.

    Sent exactly once, at the head of the transcript, and never rebuilt - that is
    what keeps llama.cpp's prefix cache warm across the whole run.
    """
    out = []
    window = pack.get("window") or {}
    totals = pack.get("totals") or {}
    baseline = pack.get("baseline") or {}

    out.append(f"WINDOW  {window.get('start')} .. {window.get('end')}  (24h)")
    out.append(
        "TOTALS  %s log lines across %s services on %s VMs; catalog holds %s known signatures"
        % (
            human_count(totals.get("lines_24h")),
            totals.get("services"),
            totals.get("vms"),
            totals.get("catalog_signatures"),
        )
    )
    out.append(
        "BASELINE  %s samples over %s of %s configured days; anomaly threshold |z| >= %s (median/MAD)"
        % (
            baseline.get("samples"),
            baseline.get("days_available"),
            baseline.get("days_configured"),
            baseline.get("z_threshold"),
        )
    )
    if (baseline.get("days_available") or 0) < 3:
        out.append("  NOTE: baseline is still filling. Treat anomaly scores as provisional.")

    topology = pack.get("topology") or {}
    if topology:
        out.append("")
        out.append("TOPOLOGY (for blast-radius reasoning: services sharing a VM share a failure domain)")
        for vm in sorted(topology):
            out.append(f"  {vm}: {', '.join(topology[vm]) or '-'}")

    def section(title, body):
        out.append("")
        out.append(f"## {title}")
        out.append(body)

    if pack.get("failed_units"):
        section(
            "FAILED SYSTEMD UNITS",
            render_table(
                ["ref", "vm", "unit", "state"],
                [[row["ref"], row["vm"], row["unit"], row.get("state", "-")] for row in pack["failed_units"]],
            ),
        )

    if pack.get("scrape_problems"):
        section(
            "UNREACHABLE EXPORTERS",
            render_table(["ref", "vm"], [[row["ref"], row["vm"]] for row in pack["scrape_problems"]]),
        )

    if pack.get("disk"):
        section(
            "FILESYSTEMS (>=80% used, or filling within 30 days; deduplicated by device)",
            render_table(
                ["ref", "vm", "mount", "avail", "used%", "days_to_full", "bind_mounts"],
                [
                    [
                        r["ref"], r["vm"], r["mountpoint"], r["avail"],
                        r["pct_used"], r["days_to_full"], r.get("shared_mounts"),
                    ]
                    for r in pack["disk"]
                ],
            )
            + "\n(days_to_full is a linear extrapolation of the 24h trend; treat it as a"
            "\n direction, not a deadline, and only trust it on an already-full volume)",
        )

    if pack.get("memory"):
        section(
            "MEMORY PRESSURE (>=85% used)",
            render_table(
                ["ref", "vm", "used%", "avail"],
                [[r["ref"], r["vm"], r["pct_used"], r["avail"]] for r in pack["memory"]],
            ),
        )

    if pack.get("reboots"):
        section(
            "RECENT BOOTS (uptime under 24h)",
            render_table(
                ["ref", "vm", "uptime_h"], [[r["ref"], r["vm"], r["uptime_hours"]] for r in pack["reboots"]]
            ),
        )

    def signature_table(rows, extra_headers=(), extra_keys=()):
        headers = ["ref", "vm", "service", "sev", "today", "days_seen"] + list(extra_headers)
        body = []
        for row in rows:
            body.append(
                [
                    row["ref"],
                    row["vm"],
                    row["service"],
                    row["severity"],
                    row["today"],
                    row["days_seen"],
                ]
                + [row.get(key) for key in extra_keys]
            )
        table = render_table(headers, body, limit=40)
        detail = []
        for row in rows[:40]:
            detail.append(f"  {row['ref']}  {clip(row.get('example') or row.get('signature') or '', 240)}")
        return table + ("\n\n" + "\n".join(detail) if detail else "")

    if pack.get("new_signatures"):
        section(
            "NEW - first observed in this window, never seen before in the catalog",
            signature_table(pack["new_signatures"]),
        )

    if pack.get("escalating"):
        section(
            "ESCALATING - count today is far above this signature's own baseline",
            signature_table(pack["escalating"], ("median", "z"), ("median", "z")),
        )

    if pack.get("went_silent"):
        section(
            "WENT SILENT - logged consistently for days, then nothing in this window",
            signature_table(pack["went_silent"], ("prev_median", "days_hist"), ("median", "days_of_history")),
        )

    if pack.get("ongoing"):
        section(
            "ONGOING - error/critical signatures still present, already known",
            signature_table(pack["ongoing"]),
        )

    if pack.get("volume_anomalies"):
        section(
            "VOLUME ANOMALIES - total line count far off this stream's own baseline",
            render_table(
                ["ref", "vm", "service", "today", "median", "z"],
                [
                    [r["ref"], r["vm"], r["service"], r["today"], r.get("median"), r.get("z")]
                    for r in pack["volume_anomalies"]
                ],
                limit=20,
            ),
        )

    section(
        "VOLUME (all streams, for context)",
        render_table(
            ["vm", "service", "lines"],
            [[r["vm"], r["service"], r["lines"]] for r in pack.get("volume") or []],
            limit=30,
        ),
    )

    if pack.get("suppressed_noise"):
        out.append("")
        out.append(
            "SUPPRESSED AS KNOWN NOISE (volume only, do not narrate unless something structural changed): "
            + ", ".join(
                f"{r['vm']}/{r['service']}={human_count(r['lines'])}" for r in pack["suppressed_noise"]
            )
        )

    if pack.get("warnings"):
        out.append("")
        out.append("COLLECTION WARNINGS (evidence may be incomplete):")
        for warning in pack["warnings"]:
            out.append(f"  - {warning}")

    return "\n".join(out)


# --------------------------------------------------------------------------
# llama client with measured GPU accounting
# --------------------------------------------------------------------------

class GpuBudget:
    """Budget in GPU milliseconds actually reported by llama-server.

    llama.cpp returns a `timings` object per response with prompt_ms and
    predicted_ms. That is measured compute, so it is immune to the two things that
    make wall-clock budgeting wrong here: time spent waiting on Loki, and prefill
    that was skipped because the KV cache already held the prefix.
    """

    def __init__(self, total_seconds: float, reserve_seconds: float):
        self.total_ms = float(total_seconds) * 1000.0
        self.reserve_ms = float(reserve_seconds) * 1000.0
        self.spent_ms = 0.0
        self.prompt_tokens = 0
        self.completion_tokens = 0
        self.cached_tokens = 0
        self.calls = 0

    def record(self, response) -> None:
        self.calls += 1
        timings = response.get("timings") or {}
        prompt_ms = safe_float(timings.get("prompt_ms"))
        predicted_ms = safe_float(timings.get("predicted_ms"))
        usage = response.get("usage") or {}
        prompt_tokens = int(usage.get("prompt_tokens") or timings.get("prompt_n") or 0)
        completion_tokens = int(usage.get("completion_tokens") or timings.get("predicted_n") or 0)
        self.prompt_tokens += prompt_tokens
        self.completion_tokens += completion_tokens
        cached = usage.get("prompt_tokens_details") or {}
        self.cached_tokens += int(cached.get("cached_tokens") or 0)
        if prompt_ms is None and predicted_ms is None:
            # No timings extension: fall back to the measured hardware rates.
            prompt_ms = prompt_tokens / 220.0 * 1000.0
            predicted_ms = completion_tokens / 20.0 * 1000.0
        self.spent_ms += (prompt_ms or 0.0) + (predicted_ms or 0.0)

    @property
    def spent_seconds(self) -> float:
        return self.spent_ms / 1000.0

    def remaining_for_tools_ms(self) -> float:
        return self.total_ms - self.reserve_ms - self.spent_ms

    def tools_exhausted(self) -> bool:
        return self.remaining_for_tools_ms() <= 0

    def summary(self) -> str:
        return (
            "gpu=%.1fs/%.0fs calls=%d prompt_tokens=%d cached=%d completion_tokens=%d"
            % (
                self.spent_seconds,
                self.total_ms / 1000.0,
                self.calls,
                self.prompt_tokens,
                self.cached_tokens,
                self.completion_tokens,
            )
        )


class Llama:
    def __init__(self, cfg):
        self.url = f"{cfg['url']}:{cfg['port']}{cfg['endpoint']}"
        self.model = cfg["model"]
        self.temperature = float(cfg["temperature"])
        self.timeout = int(cfg["llamaRequestTimeoutSeconds"])

    def chat(self, messages, *, max_tokens: int, tools=None, thinking: bool = False,
             response_format=None, temperature=None):
        payload = {
            "model": self.model,
            "messages": messages,
            "max_tokens": max_tokens,
            "temperature": self.temperature if temperature is None else temperature,
            "chat_template_kwargs": {"enable_thinking": bool(thinking)},
            "cache_prompt": True,
        }
        if not thinking:
            payload["reasoning_format"] = "none"
        if tools:
            payload["tools"] = tools
            payload["tool_choice"] = "auto"
        if response_format is not None:
            payload["response_format"] = response_format
        try:
            return http_post_json(self.url, payload, timeout=self.timeout)
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"llama-server HTTP {exc.code}: {clip(squeeze(body), 400)}") from exc
        except urllib.error.URLError as exc:
            raise RuntimeError(f"llama-server unreachable: {exc}") from exc


def strip_think(text: str) -> str:
    text = re.sub(r"<think>.*?</think>", "", text or "", flags=re.DOTALL)
    return text.strip()


def response_message(response):
    choice = (response.get("choices") or [{}])[0]
    return choice.get("message") or {}, choice.get("finish_reason")


def message_text(message) -> str:
    content = message.get("content")
    if isinstance(content, list):
        content = "".join(
            part.get("text", "") if isinstance(part, dict) else str(part) for part in content
        )
    return strip_think(content or "")


def extract_json_object(text: str):
    cleaned = (text or "").strip()
    if cleaned.startswith("```"):
        cleaned = "\n".join(line for line in cleaned.splitlines() if not line.startswith("```")).strip()
    try:
        return json.loads(cleaned)
    except json.JSONDecodeError:
        pass
    depth = 0
    start = None
    for index, char in enumerate(cleaned):
        if char == "{":
            if depth == 0:
                start = index
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0 and start is not None:
                try:
                    return json.loads(cleaned[start : index + 1])
                except json.JSONDecodeError:
                    start = None
    raise ValueError("no JSON object found in model output")


# --------------------------------------------------------------------------
# tools - read-only by construction
# --------------------------------------------------------------------------

METRIC_FUNCTION = re.compile(
    r"\b(count_over_time|rate|bytes_over_time|sum_over_time|avg_over_time|"
    r"quantile_over_time|absent_over_time|bytes_rate)\s*\("
)


class Tools:
    """The agent's entire capability surface.

    Every tool reads. None writes, executes, or mutates. The boundary is
    structural rather than a prompt instruction, so there is no privileged path
    for the model to be talked into using.
    """

    def __init__(self, cfg, loki, prom, pack, now):
        self.cfg = cfg
        self.loki = loki
        self.prom = prom
        self.pack = pack
        self.now = now
        self.max_chars = int(cfg["toolResultMaxChars"])
        self.notes = []
        self.calls = []
        self.seen = set()

    def schema(self):
        return [
            {
                "type": "function",
                "function": {
                    "name": "logs_count",
                    "description": (
                        "Exact log line counts over a window using LogQL metric queries. "
                        "This is the tool to reach for first: it returns true totals, not a sample. "
                        "Give a stream selector and optional grouping labels."
                    ),
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "selector": {
                                "type": "string",
                                "description": 'Stream selector plus optional filters, e.g. {vm="SOTO", service="jellyfin"} |~ "(?i)error"',
                            },
                            "by": {
                                "type": "array",
                                "items": {"type": "string"},
                                "description": 'Labels to group by, e.g. ["vm","service"]. Empty for a single total.',
                            },
                            "window": {"type": "string", "description": 'Window such as "1h" or "24h". Default 24h.'},
                            "step": {
                                "type": "string",
                                "description": 'If set (e.g. "1h"), return a time series over 24h instead of one total. Use this to find WHEN something happened.',
                            },
                        },
                        "required": ["selector"],
                    },
                },
            },
            {
                "type": "function",
                "function": {
                    "name": "logs_sample",
                    "description": "Fetch actual log lines matching a selector. Use after logs_count, to read the text behind a number.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "selector": {"type": "string"},
                            "limit": {"type": "integer", "description": "Max lines, capped at 40."},
                            "window": {"type": "string", "description": 'Lookback such as "24h". Default 24h.'},
                        },
                        "required": ["selector"],
                    },
                },
            },
            {
                "type": "function",
                "function": {
                    "name": "logs_labels",
                    "description": "List label names, or the values of one label. Use to discover what exists rather than guessing selectors.",
                    "parameters": {
                        "type": "object",
                        "properties": {"label": {"type": "string", "description": 'e.g. "service" or "vm". Omit to list label names.'}},
                    },
                },
            },
            {
                "type": "function",
                "function": {
                    "name": "metrics_query",
                    "description": "Instant PromQL query against Prometheus (node_exporter: cpu, memory, disk, systemd unit states, up).",
                    "parameters": {
                        "type": "object",
                        "properties": {"expr": {"type": "string"}},
                        "required": ["expr"],
                    },
                },
            },
            {
                "type": "function",
                "function": {
                    "name": "metrics_range",
                    "description": "PromQL range query over 24h, downsampled. Use to correlate a log spike with CPU, memory or disk movement.",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "expr": {"type": "string"},
                            "step": {"type": "string", "description": 'Step such as "1h". Default 1h.'},
                        },
                        "required": ["expr"],
                    },
                },
            },
            {
                "type": "function",
                "function": {
                    "name": "signature_history",
                    "description": "Full day-by-day history of a signature ref from the catalog. Answers 'is this actually new, or did it just fall out of a sample'.",
                    "parameters": {
                        "type": "object",
                        "properties": {"ref": {"type": "string", "description": 'A sig: ref from the evidence pack.'}},
                        "required": ["ref"],
                    },
                },
            },
            {
                "type": "function",
                "function": {
                    "name": "note",
                    "description": (
                        "Record a finding you have confirmed, with the refs that support it. "
                        "Notes are carried verbatim into the final digest. Keep each note to one "
                        "or two sentences and write one note per finding; a note long enough to "
                        "overrun the turn limit is lost entirely."
                    ),
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "text": {
                                "type": "string",
                                "maxLength": 400,
                                "description": "One or two sentences. Save the prose for the digest.",
                            },
                            "refs": {"type": "array", "items": {"type": "string"}},
                        },
                        "required": ["text"],
                    },
                },
            },
            {
                "type": "function",
                "function": {
                    "name": "done",
                    "description": "Stop investigating. Call this as soon as more queries would not change what the digest says.",
                    "parameters": {
                        "type": "object",
                        "properties": {"reason": {"type": "string"}},
                    },
                },
            },
        ]

    # -- dispatch --------------------------------------------------------

    def call(self, name: str, arguments: dict):
        handler = getattr(self, f"_tool_{name}", None)
        if handler is None:
            return f"error: unknown tool {name!r}"

        # Repeating a query burns GPU for a result already in the transcript.
        # Observed in practice: the same truncated logs_sample issued three times
        # in a row. Refuse the repeat and say so rather than paying for it again.
        fingerprint = json.dumps([name, arguments or {}], sort_keys=True)
        if name not in ("note", "done") and fingerprint in self.seen:
            return (
                "error: you already ran this exact query earlier in this session and the "
                "result is above. Ask something different, or call done."
            )
        self.seen.add(fingerprint)

        try:
            result = handler(arguments or {})
        except QueryError as exc:
            return f"query error: {exc}"
        except Exception as exc:  # a broken tool call must not kill the run
            return f"error: {type(exc).__name__}: {clip(str(exc), 200)}"
        result = str(result)
        if len(result) > self.max_chars:
            result = (
                result[: self.max_chars]
                + f"\n... TRUNCATED at {self.max_chars} chars. Narrow the query (add a filter, group by fewer labels, or shorten the window)."
            )
        return result

    # -- implementations --------------------------------------------------

    def _window(self, arguments, default="24h"):
        window = squeeze(arguments.get("window") or default)
        if not re.fullmatch(r"\d+[smhd]", window):
            window = default
        return window

    def _tool_logs_count(self, arguments):
        selector = squeeze(arguments.get("selector"))
        if not selector:
            return "error: selector is required"
        if METRIC_FUNCTION.search(selector) or selector.lstrip().startswith("sum"):
            return (
                "error: pass only a stream selector plus filters; this tool wraps it in "
                "count_over_time for you. Example: {vm=\"SOTO\", service=\"jellyfin\"} |~ \"(?i)error\""
            )
        window = self._window(arguments)
        by = [squeeze(item) for item in (arguments.get("by") or []) if squeeze(item)]
        grouping = f" by ({', '.join(by)})" if by else ""
        step = squeeze(arguments.get("step") or "")

        if step and re.fullmatch(r"\d+[smhd]", step):
            expr = f"sum{grouping} (count_over_time({selector}[{step}]))"
            seconds = duration_seconds(step)
            rows = self.loki.series(expr, self.now - timedelta(hours=24), self.now, max(60, seconds))
            if not rows:
                return f"no data\nquery: {expr}"
            out = [f"query: {expr}", ""]
            for labels, points in rows[:12]:
                name = ", ".join(f"{k}={v}" for k, v in sorted(labels.items())) or "total"
                series = " ".join(
                    f"{datetime.fromtimestamp(ts, timezone.utc).strftime('%H:%M')}={int(value or 0)}"
                    for ts, value in points
                    if value
                )
                out.append(f"{name}: {series or '(all zero)'}")
            return "\n".join(out)

        expr = f"sum{grouping} (count_over_time({selector}[{window}]))"
        rows = self.loki.instant(expr, self.now)
        if not rows:
            return f"no data (zero matching lines)\nquery: {expr}"
        headers = (by or ["total"]) + ["count"]
        body = [
            [labels.get(key, "-") for key in by] + [int(value or 0)]
            if by
            else ["total", int(value or 0)]
            for labels, value in sorted(rows, key=lambda row: -(row[1] or 0))
        ]
        return f"query: {expr}\n\n" + render_table(headers, body, limit=40)

    def _tool_logs_sample(self, arguments):
        selector = squeeze(arguments.get("selector"))
        if not selector:
            return "error: selector is required"
        limit = max(1, min(int(arguments.get("limit") or 12), 40))
        window = self._window(arguments)
        start = self.now - timedelta(seconds=duration_seconds(window))
        rows = self.loki.streams(selector, start, self.now, limit, "backward")
        if not rows:
            return f"no matching lines\nquery: {selector}"
        out = [f"query: {selector}  (last {limit} of the window)", ""]
        for labels, ts, payload, raw in rows:
            stamp = datetime.fromtimestamp(ts / 1e9, timezone.utc).strftime("%m-%d %H:%M:%S")
            vm = labels.get("vm", "-")
            service = labels.get("service", "-")
            out.append(f"{stamp} {vm}/{service} {clip(message_of(payload, raw), 260)}")
        return "\n".join(out)

    def _tool_logs_labels(self, arguments):
        label = squeeze(arguments.get("label") or "")
        if not label:
            return "label names: " + ", ".join(self.loki.labels())
        values = self.loki.label_values(label)
        return f"values of {label} ({len(values)}): " + ", ".join(values)

    def _tool_metrics_query(self, arguments):
        expr = squeeze(arguments.get("expr"))
        if not expr:
            return "error: expr is required"
        rows = self.prom.instant(expr, self.now)
        if not rows:
            return f"no data\nquery: {expr}"
        body = []
        for labels, value in sorted(rows, key=lambda row: -(row[1] or 0))[:40]:
            name = ", ".join(f"{k}={v}" for k, v in sorted(labels.items()) if k != "__name__")
            body.append([clip(name or "-", 90), f"{value:.4g}" if value is not None else "-"])
        return f"query: {expr}\n\n" + render_table(["labels", "value"], body, limit=40)

    def _tool_metrics_range(self, arguments):
        expr = squeeze(arguments.get("expr"))
        if not expr:
            return "error: expr is required"
        step = squeeze(arguments.get("step") or "1h")
        if not re.fullmatch(r"\d+[smhd]", step):
            step = "1h"
        rows = self.prom.series(expr, self.now - timedelta(hours=24), self.now, duration_seconds(step))
        if not rows:
            return f"no data\nquery: {expr}"
        out = [f"query: {expr} step={step}", ""]
        for labels, points in rows[:10]:
            name = ", ".join(f"{k}={v}" for k, v in sorted(labels.items()) if k != "__name__")
            series = " ".join(
                f"{datetime.fromtimestamp(ts, timezone.utc).strftime('%H:%M')}={value:.4g}"
                for ts, value in points[-24:]
                if value is not None
            )
            out.append(f"{clip(name or 'value', 80)}: {series}")
        return "\n".join(out)

    def _tool_signature_history(self, arguments):
        ref = squeeze(arguments.get("ref"))
        entry = (self.pack.get("refs") or {}).get(ref)
        if entry is None:
            return f"error: unknown ref {ref!r}. Refs come from the evidence pack."
        if entry.get("kind") != "signature":
            return f"{ref} is a {entry.get('kind')} ref, not a signature:\n" + json.dumps(entry, sort_keys=True)
        catalog_path = os.path.join(self.cfg["stateDir"], "catalog.json")
        catalog = Catalog.load(catalog_path)
        record = catalog.signatures.get(ref)
        if record is None:
            return f"error: {ref} is not in the catalog"
        days = record.get("days") or {}
        body = [[day, count] for day, count in sorted(days.items())]
        return (
            f"{ref}  {record.get('vm')}/{record.get('service')}  severity={record.get('severity')}\n"
            f"first_seen={record.get('first_seen')}  last_seen={record.get('last_seen')}  total={record.get('total')}\n"
            f"signature: {record.get('signature')}\n"
            f"example: {clip(record.get('example') or '', 300)}\n\n"
            + render_table(["day", "count"], body)
        )

    def _tool_note(self, arguments):
        text = squeeze(arguments.get("text"))
        if not text:
            return "error: text is required"
        refs = [squeeze(item) for item in (arguments.get("refs") or []) if squeeze(item)]
        known = set((self.pack.get("refs") or {}).keys())
        unknown = [ref for ref in refs if ref not in known]
        self.notes.append({"text": text, "refs": [ref for ref in refs if ref in known]})
        if unknown:
            return f"noted, but these refs do not exist and were dropped: {', '.join(unknown)}"
        return "noted"

    def _tool_done(self, arguments):
        return "ok"


def duration_seconds(text: str) -> int:
    units = {"s": 1, "m": 60, "h": 3600, "d": 86400}
    match = re.fullmatch(r"(\d+)([smhd])", squeeze(text))
    if not match:
        return 3600
    return int(match.group(1)) * units[match.group(2)]


# --------------------------------------------------------------------------
# prompts
# --------------------------------------------------------------------------

INVESTIGATOR_SYSTEM = """\
You are the on-call engineer for a small NixOS homelab, reviewing the last 24 hours.

You have been handed an evidence pack that was computed deterministically, with exact
counts over the full window. It is not a sample. Numbers in it are true totals.

The pack has already answered, in Python and without guessing:
  - what is genuinely NEW (never present in the signature catalog before)
  - what is ESCALATING against its own historical baseline
  - what WENT SILENT after logging consistently for days
  - which systemd units failed, which filesystems are filling, which VMs rebooted

So do not spend queries rediscovering any of that. Your job is to work out which of
those facts actually MATTER, and why - which usually means establishing:
  - blast radius: one service, or every service on that VM?
  - timing: a single burst, or sustained? does it line up with a reboot or a spike?
  - causation: does a log spike coincide with memory pressure, disk, or a restart?
  - consequence: did anything downstream actually break, or was it retried and fine?

Ground rules:
  - Every claim you end up making must trace to a ref from the pack or to a tool result.
    If you cannot support it, do not claim it.
  - Absence of evidence is not evidence. If a service logged nothing, say you do not
    know why rather than inventing a cause.
  - Use `note` the moment you confirm something, with its refs. Notes survive into the
    digest verbatim; anything not noted may be lost.
  - You are on a GPU budget. Prefer one well-aimed query over three vague ones. Call
    `done` as soon as further queries would not change what the digest says. Stopping
    early is a good outcome, not a failure.
  - A quiet day is a real and common result. Do not manufacture concern to fill space.

You have read-only access. You cannot change anything, and you should not pretend to.
"""

SYNTHESIS_SYSTEM = """\
Write the daily digest, using only the evidence pack, your tool results, and your notes.

Return JSON only, matching this schema exactly:

{
  "headline": string,
  "state": "quiet" | "notable" | "needs_attention",
  "findings": [
    {
      "title": string,
      "severity": "critical" | "warning" | "info",
      "what": string,
      "why_it_matters": string,
      "evidence": string,
      "confidence": "high" | "medium" | "low",
      "refs": [string],
      "suggested_action": string
    }
  ],
  "quiet_note": string
}

Rules that decide whether this digest is worth reading:

  - RANK BY CONSEQUENCE, not by volume. A single failed unit outranks 16000 firewall
    drops. Put the thing you would actually want to be woken for first.
  - MERGE CAUSAL CHAINS INTO ONE FINDING. If service A failing is why service B is
    retrying and why service C disabled something, that is a single incident with a
    root cause, not three findings. Report it once, name the root cause in the title,
    and list the downstream effects inside `what`. Splitting one chain across several
    findings makes a small problem look like a widespread one.
  - AT MOST 5 findings. If only one thing mattered, return one. Padding destroys the
    value of the whole digest.
  - DO NOT CONTRADICT YOURSELF OR THE EVIDENCE. Restate numbers exactly as they appear
    in the pack. If a host shows uptime 2.4h, it rebooted 2.4 hours ago, not 21 hours
    ago. If two numbers you are about to write disagree, re-read the pack.
  - A SERVICE LOGGING NOTHING IS NOT EVIDENCE THAT IT IS FINE, nor that it is broken.
    Say the logs are silent and that you cannot tell which, or check with a tool.
  - Every finding MUST cite at least one real ref. Findings whose refs do not resolve
    are discarded before the digest is written, so an uncited finding is simply lost.
  - `evidence` must contain concrete numbers you actually saw - counts, medians,
    z-scores, percentages, timestamps. Not "logs indicate" or "several occurrences".
  - `why_it_matters` must say what breaks for a user or an operator if this continues.
    If nothing does, the finding is `info` at most, and probably should not be included.
  - `suggested_action` is a concrete command or check, or the empty string. Never
    recommend tools this fleet does not run. Never suggest anything be restarted or
    changed unless the evidence directly supports it. You cannot execute anything;
    this is advice for a human.
  - `confidence` must be honest. Say "low" when you inferred rather than measured.
  - If nothing meaningful happened, set state="quiet", return an EMPTY findings array,
    and write one plain sentence in quiet_note describing what normal looked like.
    That is a complete and successful digest.
  - `headline` is one sentence a person could read on a phone and know whether to care.

Do not restate the topology, do not summarize routine noise, do not include a section
just because it exists.
"""


# --------------------------------------------------------------------------
# reason phase
# --------------------------------------------------------------------------

def investigate(cfg, llama, tools, budget, pack_text):
    messages = [
        {"role": "system", "content": INVESTIGATOR_SYSTEM},
        {"role": "user", "content": "EVIDENCE PACK\n\n" + pack_text},
    ]
    schema = tools.schema()
    max_calls = int(cfg["maxToolCalls"])
    used = 0
    nudged = False

    while used < max_calls:
        # Left alone the model investigates until it hits the call cap and records
        # nothing. One reminder at the halfway mark converts queries into notes.
        if not nudged and (used >= max_calls // 2 or budget.spent_ms >= budget.total_ms * 0.4):
            nudged = True
            messages.append(
                {
                    "role": "user",
                    "content": (
                        f"Budget check: {used}/{max_calls} tool calls used, "
                        f"{budget.spent_seconds:.0f}s of {budget.total_ms / 1000:.0f}s GPU spent, "
                        f"{len(tools.notes)} findings recorded so far.\n"
                        "Record what you have already confirmed with `note` now, including its refs. "
                        "Then either investigate the single most important open question, or call `done`."
                    ),
                }
            )

        if budget.tools_exhausted():
            log_info("investigation: GPU budget reserve reached, moving to synthesis")
            messages.append(
                {
                    "role": "user",
                    "content": "GPU budget for investigation is exhausted. Stop querying now.",
                }
            )
            break

        try:
            response = llama.chat(
                messages,
                max_tokens=int(cfg["investigatorMaxTokens"]),
                tools=schema,
                thinking=False,
            )
        except RuntimeError as exc:
            log_info(f"investigation: llama call failed: {exc}")
            break
        budget.record(response)
        message, finish_reason = response_message(response)
        tool_calls = message.get("tool_calls") or []

        # Normalize before the assistant turn is appended.
        #
        # Two problems are fixed here. Some llama.cpp builds omit tool call ids,
        # leaving tool replies referencing ids that never appear. And a turn that
        # hits the token cap mid-argument leaves truncated JSON like '{"vm": "KAIZ'
        # in the transcript, which llama.cpp then fails to re-parse on EVERY
        # later request, killing the run with a 500 long after the fact.
        parsed_arguments = []
        for index, call in enumerate(tool_calls):
            if not call.get("id"):
                call["id"] = f"call_{used}_{index}"
            function = call.setdefault("function", {})
            raw = function.get("arguments")
            if isinstance(raw, str):
                try:
                    arguments = json.loads(raw or "{}")
                except json.JSONDecodeError:
                    arguments = {}
                    log_info(
                        f"investigation: discarded malformed arguments for {function.get('name')!r} "
                        f"(likely truncated at investigatorMaxTokens): {clip(raw, 120)}"
                    )
            else:
                arguments = raw or {}
            if not isinstance(arguments, dict):
                arguments = {}
            # Write back canonical JSON so the transcript stays re-parseable.
            function["arguments"] = json.dumps(arguments, sort_keys=True)
            parsed_arguments.append(arguments)

        messages.append(
            {
                "role": "assistant",
                "content": message.get("content") or "",
                **({"tool_calls": tool_calls} if tool_calls else {}),
            }
        )

        if not tool_calls:
            text = message_text(message)
            log_info(f"investigation: model stopped without a tool call ({finish_reason}); {budget.summary()}")
            if text:
                tools.notes.append({"text": squeeze(text)[:1500], "refs": []})
            break

        stop = False
        for call, arguments in zip(tool_calls, parsed_arguments):
            name = (call.get("function") or {}).get("name") or ""
            if finish_reason == "length" and not arguments:
                result = (
                    "error: your previous turn was cut off by the token limit before the "
                    "arguments were complete. Reissue it with a shorter, more specific query."
                )
            else:
                result = tools.call(name, arguments)
            used += 1
            tools.calls.append({"tool": name, "arguments": arguments, "chars": len(result)})
            log_info(f"investigation: tool {name} -> {len(result)} chars ({budget.summary()})")
            messages.append(
                {"role": "tool", "tool_call_id": call["id"], "content": result}
            )
            if name == "done":
                stop = True
        if stop:
            log_info("investigation: model called done")
            break

    return messages


def synthesize(cfg, llama, tools, budget, messages, pack_text):
    notes_text = "\n".join(
        f"- {note['text']}" + (f"  [refs: {', '.join(note['refs'])}]" if note["refs"] else "")
        for note in tools.notes
    ) or "(no notes were recorded)"

    prompt = [
        *messages,
        {
            "role": "user",
            "content": SYNTHESIS_SYSTEM + "\n\nYOUR CONFIRMED NOTES\n" + notes_text,
        },
    ]

    # A transcript-free fallback. If llama.cpp truncates one of its own tool calls
    # at the token cap it cannot re-parse that turn afterwards, and every later
    # request against the transcript returns HTTP 500 - including this one. This
    # prompt carries no tool_calls at all, so it cannot inherit that failure.
    clean_prompt = [
        {"role": "system", "content": INVESTIGATOR_SYSTEM},
        {
            "role": "user",
            "content": (
                "EVIDENCE PACK\n\n"
                + pack_text
                + "\n\nFINDINGS CONFIRMED DURING INVESTIGATION\n"
                + notes_text
                + "\n\n"
                + SYNTHESIS_SYSTEM
            ),
        },
    ]

    thinking_first = bool(cfg.get("thinkingForSynthesis", False))
    max_tokens = int(cfg["synthesisMaxTokens"])
    attempts = []
    if thinking_first:
        attempts.append(("full transcript, thinking", prompt, True))
    attempts.append(("full transcript, no thinking", prompt, False))
    attempts.append(("clean prompt, no thinking", clean_prompt, False))

    last_error = None
    for index, (label, messages_for_attempt, thinking) in enumerate(attempts):
        try:
            response = llama.chat(
                messages_for_attempt,
                max_tokens=max_tokens,
                thinking=thinking,
                response_format={"type": "json_object"},
                temperature=float(cfg.get("synthesisTemperature", 0.4)),
            )
        except RuntimeError as exc:
            last_error = str(exc)
            log_info(f"synthesis attempt {index + 1} ({label}) failed: {clip(last_error, 200)}")
            continue
        budget.record(response)
        message, finish_reason = response_message(response)
        text = message_text(message)
        if text:
            try:
                return extract_json_object(text)
            except ValueError as exc:
                last_error = f"unparseable synthesis output: {exc}"
        else:
            # With thinking on, the whole allowance can go into the reasoning
            # block leaving no JSON. Retrying without it spends those tokens on
            # the answer instead.
            last_error = f"empty content (finish_reason={finish_reason})"
        log_info(f"synthesis attempt {index + 1} ({label}) failed: {clip(last_error, 200)}")

    raise RuntimeError(f"synthesis failed after {len(attempts)} attempts: {last_error}")


def validate_digest(raw, pack):
    """Drop anything the evidence does not support.

    A finding whose refs do not resolve is unverifiable by construction, so it is
    removed rather than published. This is the cheapest hallucination control
    available: it costs no GPU and it cannot be talked around.
    """
    known_refs = set((pack.get("refs") or {}).keys())
    findings = []
    dropped = []
    for item in raw.get("findings") or []:
        if not isinstance(item, dict):
            continue
        title = squeeze(item.get("title"))
        if not title:
            continue
        refs = [squeeze(ref) for ref in (item.get("refs") or []) if squeeze(ref)]
        valid = [ref for ref in refs if ref in known_refs]
        if not valid:
            dropped.append(title)
            continue
        severity = squeeze(item.get("severity")).lower()
        if severity not in ("critical", "warning", "info"):
            severity = "info"
        confidence = squeeze(item.get("confidence")).lower()
        if confidence not in ("high", "medium", "low"):
            confidence = "medium"
        findings.append(
            {
                "title": title,
                "severity": severity,
                "what": squeeze(item.get("what")),
                "why_it_matters": squeeze(item.get("why_it_matters")),
                "evidence": squeeze(item.get("evidence")),
                "confidence": confidence,
                "refs": valid,
                "suggested_action": squeeze(item.get("suggested_action")),
            }
        )

    rank = {"critical": 0, "warning": 1, "info": 2}
    findings.sort(key=lambda item: rank.get(item["severity"], 2))
    findings = findings[:5]

    state = squeeze(raw.get("state")).lower()
    if state not in ("quiet", "notable", "needs_attention"):
        state = "needs_attention" if any(f["severity"] == "critical" for f in findings) else (
            "notable" if findings else "quiet"
        )
    # A digest whose findings were all discarded as unsupported is not a quiet
    # day, it is a failed one. Do not let it read as reassuring.
    if not findings and dropped:
        state = "notable"
    return {
        "headline": squeeze(raw.get("headline")),
        "state": state,
        "findings": findings,
        "quiet_note": squeeze(raw.get("quiet_note")),
        "dropped_unsupported": dropped,
    }


def render_digest(digest, pack, budget, tools, now) -> str:
    totals = pack.get("totals") or {}
    state_label = {
        "quiet": "quiet",
        "notable": "notable",
        "needs_attention": "NEEDS ATTENTION",
    }.get(digest["state"], digest["state"])

    lines = [
        f"# Homelab digest - {now.strftime('%Y-%m-%d')} [{state_label}]",
        "",
        digest["headline"] or "(no headline)",
        "",
        "%s lines / %s services / %s VMs in 24h."
        % (
            human_count(totals.get("lines_24h")),
            totals.get("services"),
            totals.get("vms"),
        ),
        "",
    ]

    severity_marker = {"critical": "[!!]", "warning": "[! ]", "info": "[  ]"}
    refs_index = pack.get("refs") or {}

    if digest["findings"]:
        for index, finding in enumerate(digest["findings"], start=1):
            lines.append(
                f"## {index}. {severity_marker.get(finding['severity'], '[  ]')} {finding['title']}"
            )
            if finding["what"]:
                lines.append(finding["what"])
            if finding["why_it_matters"]:
                lines.append(f"**Why it matters:** {finding['why_it_matters']}")
            if finding["evidence"]:
                lines.append(f"**Evidence:** {finding['evidence']}")
            if finding["suggested_action"]:
                lines.append(f"**Suggested:** `{finding['suggested_action']}` (not executed)")
            lines.append(f"*confidence: {finding['confidence']}*")
            queries = []
            for ref in finding["refs"]:
                entry = refs_index.get(ref) or {}
                query = entry.get("query")
                if query and query not in queries:
                    queries.append(query)
            if queries:
                lines.append("")
                lines.append("Verify:")
                for query in queries[:3]:
                    lines.append(f"    {query}")
            lines.append("")
    else:
        lines.append(digest["quiet_note"] or "Nothing notable in this window.")
        lines.append("")

    facts = []
    if pack.get("failed_units"):
        facts.append(f"failed units: {len(pack['failed_units'])}")
    if pack.get("new_signatures"):
        facts.append(f"new signatures: {len(pack['new_signatures'])}")
    if pack.get("escalating"):
        facts.append(f"escalating: {len(pack['escalating'])}")
    if pack.get("went_silent"):
        facts.append(f"went silent: {len(pack['went_silent'])}")
    if pack.get("disk"):
        soonest = pack["disk"][0]
        if soonest.get("days_to_full") is not None:
            facts.append(f"soonest disk full: {soonest['vm']}{soonest['mountpoint']} in {soonest['days_to_full']}d")
    if facts:
        lines.append("---")
        lines.append("Baseline: " + "; ".join(facts) + ".")

    if digest.get("dropped_unsupported"):
        lines.append(
            "Dropped %d unsupported finding(s): %s."
            % (len(digest["dropped_unsupported"]), "; ".join(digest["dropped_unsupported"][:3]))
        )

    if pack.get("warnings"):
        lines.append("Collection warnings: " + "; ".join(pack["warnings"][:3]) + ".")

    lines.append(
        "Run: %s; tool calls: %d; generated %s."
        % (budget.summary(), len(tools.calls), iso(now))
    )
    return "\n".join(lines) + "\n"


def reason(cfg, args) -> int:
    now = utcnow()
    state_dir = cfg["stateDir"]
    os.makedirs(state_dir, exist_ok=True)

    pack_path = args.evidence or os.path.join(state_dir, "evidence.json")
    pack = read_json(pack_path)
    if pack is None:
        log_info(f"no evidence pack at {pack_path}; building one now")
        loki = Loki(cfg["lokiUrl"], timeout=int(cfg["queryTimeoutSeconds"]))
        prom = Prometheus(cfg["prometheusUrl"], timeout=int(cfg["queryTimeoutSeconds"]))
        catalog = Catalog.load(os.path.join(state_dir, "catalog.json"))
        pack = build_evidence_pack(cfg, loki, prom, catalog, now)
        write_json(pack_path, pack)

    generated = parse_iso(pack.get("generated_at") or "")
    if generated is not None:
        age_hours = (now - generated).total_seconds() / 3600.0
        if age_hours > float(cfg["packMaxAgeHours"]):
            log_info(
                f"warning: evidence pack is {age_hours:.1f}h old (limit {cfg['packMaxAgeHours']}h); "
                "the collector may not be running"
            )

    loki = Loki(cfg["lokiUrl"], timeout=int(cfg["queryTimeoutSeconds"]))
    prom = Prometheus(cfg["prometheusUrl"], timeout=int(cfg["queryTimeoutSeconds"]))
    llama = Llama(cfg)
    budget = GpuBudget(float(cfg["gpuBudgetSeconds"]), float(cfg["synthesisReserveSeconds"]))
    tools = Tools(cfg, loki, prom, pack, now)

    pack_text = render_pack(pack, cfg)
    log_info(f"evidence pack rendered to {len(pack_text)} chars (~{len(pack_text)//4} tokens)")

    if args.dry_run:
        print(pack_text)
        return 0

    messages = investigate(cfg, llama, tools, budget, pack_text)
    log_info(f"investigation complete: {budget.summary()} notes={len(tools.notes)} tools={len(tools.calls)}")

    try:
        raw = synthesize(cfg, llama, tools, budget, messages, pack_text)
    except (RuntimeError, ValueError) as exc:
        log_info(f"synthesis failed: {exc}")
        failure = (
            f"# Homelab digest - {now.strftime('%Y-%m-%d')} [FAILED]\n\n"
            f"Synthesis failed: {exc}\n\n"
            f"The evidence pack was collected successfully and is at {pack_path}.\n"
            f"{budget.summary()}\n"
        )
        write_text(os.path.join(state_dir, f"digest-{now.strftime('%Y-%m-%d')}.md"), failure)
        publish(cfg, loki, now, failure, pack, None)
        return 1

    digest = validate_digest(raw, pack)
    if digest["dropped_unsupported"]:
        log_info(
            "dropped %d unsupported finding(s): %s"
            % (len(digest["dropped_unsupported"]), "; ".join(digest["dropped_unsupported"]))
        )
    markdown = render_digest(digest, pack, budget, tools, now)

    day = now.strftime("%Y-%m-%d")
    write_text(os.path.join(state_dir, f"digest-{day}.md"), markdown)
    write_text(os.path.join(state_dir, "digest-latest.md"), markdown)
    write_json(os.path.join(state_dir, f"digest-{day}.json"), digest)
    write_json(
        os.path.join(state_dir, f"trace-{day}.json"),
        {
            "generated_at": iso(now),
            "gpu": {
                "seconds": round(budget.spent_seconds, 1),
                "budget_seconds": float(cfg["gpuBudgetSeconds"]),
                "calls": budget.calls,
                "prompt_tokens": budget.prompt_tokens,
                "cached_tokens": budget.cached_tokens,
                "completion_tokens": budget.completion_tokens,
            },
            "tool_calls": tools.calls,
            "notes": tools.notes,
        },
    )
    publish(cfg, loki, now, markdown, pack, digest)

    log_info(
        "digest written: state=%s findings=%d %s"
        % (digest["state"], len(digest["findings"]), budget.summary())
    )
    prune_old_files(state_dir, int(cfg["keepDigestDays"]))
    return 0


def publish(cfg, loki, now, markdown, pack, digest) -> None:
    ts_ns = to_ns(now)
    base = {"vm": cfg["digestVm"], "service": "logDigest", "source_type": "digest"}
    for kind, content in (
        ("summary", markdown),
        ("digest_json", json.dumps(digest, sort_keys=True) if digest else None),
    ):
        if not content:
            continue
        try:
            loki.push(dict(base, kind=kind), ts_ns, content)
        except Exception as exc:
            log_info(f"warning: pushing {kind} to Loki failed: {describe_http_error(exc)}")


def prune_old_files(state_dir: str, keep_days: int) -> None:
    cutoff = time.time() - keep_days * 86400
    for name in os.listdir(state_dir):
        if not re.fullmatch(r"(digest|evidence|trace)-\d{4}-\d{2}-\d{2}\.(md|json)", name):
            continue
        path = os.path.join(state_dir, name)
        try:
            if os.path.getmtime(path) < cutoff:
                os.remove(path)
        except OSError:
            pass


# --------------------------------------------------------------------------
# entry point
# --------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(description="Homelab log and metric digest.")
    parser.add_argument("--config", required=True)
    sub = parser.add_subparsers(dest="phase", required=True)

    collect_parser = sub.add_parser("collect", help="deterministic collection, no GPU")
    collect_parser.add_argument(
        "--build-pack", action="store_true", help="also write the daily evidence pack"
    )

    reason_parser = sub.add_parser("reason", help="agentic reasoning over an evidence pack")
    reason_parser.add_argument("--evidence", help="path to an evidence pack (default: stateDir/evidence.json)")
    reason_parser.add_argument(
        "--dry-run", action="store_true", help="render the pack and exit without touching the GPU"
    )

    args = parser.parse_args()
    cfg = read_json(args.config)
    if cfg is None:
        print(f"logDigest: cannot read config at {args.config}", file=sys.stderr)
        return 2

    if args.phase == "collect":
        return collect(cfg, args)
    return reason(cfg, args)


if __name__ == "__main__":
    raise SystemExit(main())
