#!/usr/bin/env python3
"""Aggregate Claude Code token usage from ~/.claude/projects transcripts.

Emits a JSON summary on stdout: the rolling 5-hour block, the last 7 days, and a
per-skill breakdown. Designed to be called once a minute by a menu bar plugin, so
parsing is incremental: transcripts are append-only JSONL, and we remember how many
bytes of each file we already folded into the bucket store.

Windows are quantised: a window includes every bucket that the boundary falls
inside, so "the last 5h" can carry up to one extra bucket of older history. With
1-minute buckets that caps the overstatement at 60s of activity (<0.4% of a 5h
block). Aligning `now` to a bucket edge makes the figures exact.

Skill attribution rule ("until end of turn"): a skill becomes active when the
assistant emits a `Skill` tool_use, and stops being active at the next real user
message. Every assistant message in between is charged to it. Nested skills charge
to the most recent one.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from datetime import datetime
from pathlib import Path

HOME = Path.home()
PROJECTS_DIR = HOME / ".claude" / "projects"
CACHE_PATH = HOME / ".claude" / "usage-bar-cache.json"
PRICING_PATH = Path(__file__).resolve().parent / "pricing.json"

CACHE_VERSION = 6
BUCKET_SECONDS = 60           # 1-minute granularity; see the note on windows below
RETAIN_DAYS = 8               # keeps the 7-day window plus a day of slack
BLOCK_SECONDS = 5 * 3600      # the rolling "5h block"

# Order of the five counters stored per (bucket, key).
FIELDS = ("in", "out", "cw5", "cw1h", "cr")
NO_SKILL = "(sin skill)"


# --------------------------------------------------------------------------- #
# parsing
# --------------------------------------------------------------------------- #

def parse_timestamp(value):
    """ISO-8601 with a trailing Z -> epoch seconds. Returns None if unparseable."""
    if not value:
        return None
    try:
        # Python's fromisoformat rejects the Z suffix before 3.11.
        from datetime import datetime

        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def is_real_user_turn(record):
    """True only for a message the human actually typed.

    Three kinds of record arrive with role=user and none of them ends a turn:
    tool results, and the harness's own injections - `isMeta` covers the local
    command caveats and pasted images, `sourceToolUseID` covers the skill body
    that Claude Code feeds back after a Skill call. Missing that last one charges
    every skill zero tokens, because the injection looks like a fresh prompt and
    closes the turn the instant the skill opens it.
    """
    if record.get("isMeta") or record.get("sourceToolUseID"):
        return False
    content = record.get("message", {}).get("content")
    if not isinstance(content, list):
        return True
    return not any(
        isinstance(block, dict) and block.get("type") == "tool_result"
        for block in content
    )


def usage_counters(usage):
    """Pull the five billable counters out of a message's usage object."""
    creation = usage.get("cache_creation") or {}
    cw1h = creation.get("ephemeral_1h_input_tokens", 0) or 0
    cw5 = creation.get("ephemeral_5m_input_tokens", 0) or 0
    if not creation:
        # Older records only carry the flat total; treat it as 5-minute cache.
        cw5 = usage.get("cache_creation_input_tokens", 0) or 0
    return (
        usage.get("input_tokens", 0) or 0,
        usage.get("output_tokens", 0) or 0,
        cw5,
        cw1h,
        usage.get("cache_read_input_tokens", 0) or 0,
    )


def add(target, key, counters):
    slot = target.get(key)
    if slot is None:
        target[key] = list(counters)
    else:
        for i, value in enumerate(counters):
            slot[i] += value


def fold_lines(lines, buckets, skill_state):
    """Fold a run of JSONL lines into `buckets`, mutating `skill_state` in place.

    `skill_state` maps the sidechain flag (main agent vs. subagent) to the skill
    currently active on that track, so a subagent's skills don't leak into the
    main transcript's attribution.
    """
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue

        track = bool(record.get("isSidechain"))
        kind = record.get("type")

        if kind == "user":
            if is_real_user_turn(record):
                skill_state[track] = None
            continue

        if kind != "assistant":
            continue

        message = record.get("message") or {}
        usage = message.get("usage") or {}
        counters = usage_counters(usage)
        timestamp = parse_timestamp(record.get("timestamp"))

        if timestamp is not None and any(counters):
            bucket = buckets.setdefault(str(int(timestamp // BUCKET_SECONDS)),
                                        {"m": {}, "s": {}})
            model = message.get("model") or "unknown"
            add(bucket["m"], model, counters)
            # Per skill we keep the model too: a subagent on a cheaper model runs
            # inside the same 5-minute bucket as the main one, so a flat
            # dollars-per-token rate for the bucket misprices the rows by up to 40%.
            add(bucket["s"].setdefault(skill_state[track] or NO_SKILL, {}), model, counters)

        # A Skill call inside this message governs everything that comes after it.
        for block in message.get("content") or []:
            if (
                isinstance(block, dict)
                and block.get("type") == "tool_use"
                and block.get("name") == "Skill"
            ):
                slug = (block.get("input") or {}).get("skill")
                if slug:
                    skill_state[track] = slug


# --------------------------------------------------------------------------- #
# incremental store
# --------------------------------------------------------------------------- #

def load_cache(cache_path=CACHE_PATH):
    empty = {"v": CACHE_VERSION, "files": {}, "buckets": {}}
    try:
        cache = json.loads(Path(cache_path).read_text())
    except (OSError, json.JSONDecodeError):
        return empty
    if cache.get("v") != CACHE_VERSION:
        return empty
    return cache


def prune(buckets, now):
    cutoff = int((now - RETAIN_DAYS * 86400) // BUCKET_SECONDS)
    for key in [k for k in buckets if int(k) < cutoff]:
        del buckets[key]


def refresh(projects_dir=PROJECTS_DIR, cache_path=CACHE_PATH, now=None):
    """Bring the bucket store up to date with everything on disk. Returns the cache."""
    now = now or time.time()
    cache_path = Path(cache_path)
    cache = load_cache(cache_path)
    files, buckets = cache["files"], cache["buckets"]

    transcripts = sorted(str(p) for p in projects_dir.glob("*/*.jsonl"))

    # A shrunken file means it was rewritten, not appended to: our stored offset no
    # longer points where we think it does, so the only safe move is a full rebuild.
    for path in transcripts:
        seen = files.get(path)
        if seen and os.path.getsize(path) < seen["offset"]:
            files, buckets = {}, {}
            cache["files"], cache["buckets"] = files, buckets
            break

    for path in transcripts:
        size = os.path.getsize(path)
        seen = files.get(path) or {"offset": 0, "skill": None, "skill_sub": None}
        if size == seen["offset"]:
            continue
        skill_state = {False: seen.get("skill"), True: seen.get("skill_sub")}
        # Binary mode: text-mode tell() returns an opaque cookie we could not compare
        # against the file size or use as a resume offset.
        with open(path, "rb") as handle:
            handle.seek(seen["offset"])
            chunk = handle.read()

        # A session being written right now can leave a half-written last line.
        # Stop at the last newline so we re-read that line on the next pass.
        cut = chunk.rfind(b"\n")
        if cut == -1:
            continue
        complete = chunk[: cut + 1]
        fold_lines(complete.splitlines(), buckets, skill_state)
        files[path] = {
            "offset": seen["offset"] + len(complete),
            "skill": skill_state[False],
            "skill_sub": skill_state[True],
        }

    # Drop transcripts that no longer exist so the cache doesn't grow forever.
    for path in [p for p in files if p not in set(transcripts)]:
        del files[path]

    prune(buckets, now)
    cache_path.parent.mkdir(parents=True, exist_ok=True)
    tmp = cache_path.with_suffix(".tmp")
    tmp.write_text(json.dumps(cache, separators=(",", ":")))
    tmp.replace(cache_path)
    return cache


# --------------------------------------------------------------------------- #
# reporting
# --------------------------------------------------------------------------- #

def load_pricing():
    pricing = json.loads(PRICING_PATH.read_text())
    return pricing["models"], pricing["aliases"], set(pricing["free"])


def plan_monthly():
    """What the subscription costs. It is NOT billed per token - this only exists
    so the report can say how far the plan stretches against API list price."""
    return (json.loads(PRICING_PATH.read_text()).get("plan") or {}).get("usd_per_month")


def cost(model, counters, pricing):
    models, aliases, free = pricing
    if model in free:
        return 0.0
    rates = models.get(aliases.get(model, model))
    if rates is None:
        return 0.0
    return sum(
        counters[i] * rates[field] for i, field in enumerate(FIELDS)
    ) / 1_000_000


def bucket_cost(bucket, pricing):
    return sum(cost(model, c, pricing) for model, c in bucket["m"].items())


def window(buckets, start, end, pricing):
    """Everything in [start, end): token breakdown, cost, and per-skill rows."""
    lo, hi = int(start // BUCKET_SECONDS), int(end // BUCKET_SECONDS)
    totals = [0] * len(FIELDS)
    dollars = 0.0
    skills = {}
    first_bucket = None

    for key, bucket in buckets.items():
        index = int(key)
        if not lo <= index <= hi:
            continue
        if first_bucket is None or index < first_bucket:
            first_bucket = index

        for counters in bucket["m"].values():
            for i, value in enumerate(counters):
                totals[i] += value
        spent = bucket_cost(bucket, pricing)
        dollars += spent

        for skill, per_model in bucket["s"].items():
            row = skills.setdefault(skill, [0, 0.0])
            for model, counters in per_model.items():
                row[0] += sum(counters)
                row[1] += cost(model, counters, pricing)

    return {
        "tokens": dict(zip(FIELDS, totals)),
        "billable": totals[0] + totals[1] + totals[2] + totals[3],
        "cost": round(dollars, 4),
        "first_bucket": first_bucket,
        "skills": sorted(
            ({"skill": s, "tokens": t, "cost": round(c, 4)} for s, (t, c) in skills.items()),
            key=lambda row: -row["cost"],
        ),
    }


def block_percentile(buckets, now, pricing, percentile=0.95):
    """What a heavy 5h block costs on this machine, from its own history.

    There is no local record of the plan's actual limit, so the only honest
    denominator for "how loaded is this block" is the user's own past blocks.
    Sampled hourly over whatever history the cache still retains.
    """
    if not buckets:
        return 0.0
    costs = {int(k): bucket_cost(b, pricing) for k, b in buckets.items()}
    span = int(BLOCK_SECONDS // BUCKET_SECONDS)
    step = int(3600 // BUCKET_SECONDS)

    samples = []
    start = min(costs)
    end_limit = int(now // BUCKET_SECONDS) - span
    while start <= end_limit:
        total = sum(v for k, v in costs.items() if start <= k < start + span)
        if total:
            samples.append(total)
        start += step

    if not samples:
        return 0.0
    samples.sort()
    return samples[min(len(samples) - 1, int(len(samples) * percentile))]


def report(cache, now=None):
    now = now or time.time()
    buckets = cache["buckets"]
    pricing = load_pricing()

    block = window(buckets, now - BLOCK_SECONDS, now, pricing)
    week = window(buckets, now - 7 * 86400, now, pricing)
    reference = block_percentile(buckets, now, pricing)

    # The rolling window frees up capacity once its oldest bucket ages out, which
    # happens 5h after that bucket ENDS - using its start yields a past timestamp.
    expires = (
        ((block["first_bucket"] + 1) * BUCKET_SECONDS) + BLOCK_SECONDS
        if block["first_bucket"] is not None
        else None
    )

    return {
        "generated_at": now,
        "block": {
            "cost": block["cost"],
            "billable": block["billable"],
            "cache_read": block["tokens"]["cr"],
            "expires_at": expires,
            "reference_p95": round(reference, 4),
            "load": round(block["cost"] / reference, 3) if reference else None,
        },
        "week": {
            "cost": week["cost"],
            "billable": week["billable"],
            "cache_read": week["tokens"]["cr"],
            # How many times over the week's API-list value covers a week of plan.
            "plan_multiple": (
                round(week["cost"] / (plan / 30 * 7), 1)
                if (plan := plan_monthly()) else None
            ),
        },
        "skills": [row for row in week["skills"] if row["skill"] != NO_SKILL][:12],
        "unattributed": next(
            (row for row in week["skills"] if row["skill"] == NO_SKILL), None
        ),
    }


# --------------------------------------------------------------------------- #
# self-test
# --------------------------------------------------------------------------- #

def self_test():
    """Fold a synthetic transcript and assert the attribution rule holds."""
    import tempfile

    def assistant(ts, tokens, blocks=None):
        return json.dumps({
            "type": "assistant",
            "timestamp": ts,
            "message": {
                "model": "claude-opus-5",
                "usage": {"input_tokens": tokens, "output_tokens": 0},
                "content": blocks or [],
            },
        })

    skill_call = [{"type": "tool_use", "name": "Skill", "input": {"skill": "demo"}}]
    lines = [
        json.dumps({"type": "user", "timestamp": "2026-09-21T10:00:00.000Z",
                    "message": {"content": "hola"}}),
        assistant("2026-09-21T10:00:01.000Z", 100, skill_call),   # charged to (sin skill)
        # The harness feeds the skill body back as a role=user record. It looks
        # like a fresh prompt and must not close the turn the skill just opened.
        json.dumps({"type": "user", "timestamp": "2026-09-21T10:00:01.500Z",
                    "isMeta": True, "sourceToolUseID": "toolu_x",
                    "message": {"content": [{"type": "text",
                                             "text": "Base directory for this skill: ..."}]}}),
        assistant("2026-09-21T10:00:02.000Z", 500),               # charged to demo
        # A subagent runs while `demo` is active on the main track. It has no skill
        # of its own, so its tokens must NOT land on demo.
        json.dumps({"type": "assistant", "timestamp": "2026-09-21T10:00:03.000Z",
                    "isSidechain": True,
                    "message": {"model": "claude-opus-5",
                                "usage": {"input_tokens": 900, "output_tokens": 0},
                                "content": []}}),
        json.dumps({"type": "user", "timestamp": "2026-09-21T10:00:04.000Z",
                    "message": {"content": [{"type": "tool_result", "content": "x"}]}}),
        assistant("2026-09-21T10:00:05.000Z", 300),               # still demo
        json.dumps({"type": "user", "timestamp": "2026-09-21T10:00:06.000Z",
                    "message": {"content": "otra cosa"}}),        # ends the turn
        assistant("2026-09-21T10:00:07.000Z", 700),               # back to (sin skill)
    ]

    buckets = {}
    fold_lines(lines, buckets, {False: None, True: None})
    def tally(store):
        out = {}
        for bucket in store.values():
            for skill, per_model in bucket["s"].items():
                out[skill] = out.get(skill, 0) + sum(sum(c) for c in per_model.values())
        return out

    totals = tally(buckets)

    failures = []
    if totals.get("demo") != 800:
        failures.append(f"demo should own 800 tokens (500 + the tool_result turn's 300), got {totals.get('demo')}")
    if totals.get(NO_SKILL) != 1700:
        failures.append(f"unattributed should be 1700 (100 + 700 + 900 sidechain), got {totals.get(NO_SKILL)}")

    # Incremental resume must reach the same numbers as one pass, including when a
    # pass lands mid-line because a session is being written to right now.
    split = len(lines[3]) // 2
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / "proj").mkdir()
        transcript = root / "proj" / "s.jsonl"
        cache_file = root / "cache.json"

        transcript.write_text("\n".join(lines[:3]) + "\n" + lines[3][:split])
        refresh(root, cache_file)                      # sees a half-written line
        with open(transcript, "a") as handle:
            handle.write(lines[3][split:] + "\n")
        refresh(root, cache_file)                      # that line is now complete
        with open(transcript, "a") as handle:
            handle.write("\n".join(lines[4:]) + "\n")
        resumed = refresh(root, cache_file)

    incremental = tally(resumed["buckets"])
    if incremental != totals:
        failures.append(f"incremental resume diverged: {incremental} != {totals}")

    # Two models inside ONE bucket, on different skills. Pricing the rows off the
    # bucket's average dollars-per-token would hand each of them $0.003; each must
    # be charged at its own model's rate instead.
    mixed = [
        json.dumps({"type": "user", "timestamp": "2026-09-21T11:00:00.000Z",
                    "message": {"content": "hola"}}),
        json.dumps({"type": "assistant", "timestamp": "2026-09-21T11:00:01.000Z",
                    "message": {"model": "claude-opus-5",          # $5/Mtok in
                                "usage": {"input_tokens": 1000, "output_tokens": 0},
                                "content": skill_call}}),
        json.dumps({"type": "assistant", "timestamp": "2026-09-21T11:00:02.000Z",
                    "message": {"model": "claude-haiku-4-5",       # $1/Mtok in
                                "usage": {"input_tokens": 1000, "output_tokens": 0},
                                "content": []}}),
    ]
    mixed_buckets = {}
    fold_lines(mixed, mixed_buckets, {False: None, True: None})
    start = parse_timestamp("2026-09-21T11:00:00.000Z")
    rows = {r["skill"]: r["cost"]
            for r in window(mixed_buckets, start - 60, start + 600, load_pricing())["skills"]}
    for skill, expected in ((NO_SKILL, 0.005), ("demo", 0.001)):
        if abs(rows.get(skill, 0) - expected) > 1e-9:
            failures.append(
                f"{skill} should cost ${expected} at its own model's rate, got ${rows.get(skill)}"
            )

    for failure in failures:
        print(f"FAIL: {failure}")
    print("self-test: " + ("PASS" if not failures else "FAILED"))
    return 1 if failures else 0


def humanize(value):
    for limit, suffix in ((1e9, "B"), (1e6, "M"), (1e3, "k")):
        if value >= limit:
            return f"{value / limit:.1f}{suffix}"
    return str(int(value))


def render_text(data):
    """The same summary the menu renders, for reading in a terminal."""
    block, week = data["block"], data["week"]
    out = []
    out.append("Bloque de 5 h (ventana rodante) — equivalente a precio de API")
    out.append(f"  ${block['cost']:,.2f}   {humanize(block['billable'])} facturables"
               f"  + {humanize(block['cache_read'])} de caché")
    if block["expires_at"]:
        when = datetime.fromtimestamp(block["expires_at"]).strftime("%H:%M")
        out.append(f"  libera a las {when}")
    if block["load"] is not None:
        out.append(f"  {block['load']:.0%} de un bloque cargado tuyo "
                   f"(p95 = ${block['reference_p95']:,.2f})")
    out.append("")
    out.append("Últimos 7 días")
    out.append(f"  ${week['cost']:,.2f}   {humanize(week['billable'])} facturables"
               f"  + {humanize(week['cache_read'])} de caché")
    if week.get("plan_multiple"):
        out.append(f"  ×{week['plan_multiple']} de lo que cuesta el plan en 7 días "
                   f"(el plan es fijo: no se cobra por token)")
    out.append("")
    out.append("Gasto por skill (7 días) — equivalente a precio de API")
    rows = list(data["skills"])
    if data.get("unattributed"):
        rows.append(data["unattributed"])
    width = max((len(row["skill"]) for row in rows), default=0)
    for row in rows:
        out.append(f"  {row['skill']:<{width}}  ${row['cost']:>10,.2f}  "
                   f"{humanize(row['tokens']):>7}")
    return "\n".join(out)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--text", action="store_true",
                        help="resumen legible en vez de JSON")
    args = parser.parse_args()

    if args.self_test:
        return self_test()

    data = report(refresh())
    print(render_text(data) if args.text else json.dumps(data, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
