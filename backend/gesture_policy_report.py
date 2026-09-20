"""Summarize CompareGesturePolicies output without treating toy data as ASL.

python3 -m backend.gesture_policy_report .runtime/gesture-experiments/native.json
"""
import argparse
import json
import statistics
from collections import defaultdict
from pathlib import Path


def quantile(values, q):
    if not values:
        return None
    values = sorted(values)
    index = (len(values) - 1) * q
    lo, hi = int(index), min(int(index) + 1, len(values) - 1)
    return round(values[lo] + (values[hi] - values[lo]) * (index - lo), 3)


def review_events(row):
    """Events applied to an unselected review; no ideal-user selection simulated."""
    previous = None
    for event in row["events"]:
        if event["phase"] == "cleared":
            previous = None
            yield event
            continue
        if row["policy"] == "segmented" and event["phase"] != "completed":
            continue
        if row["policy"] == "hybrid":
            if not event["choices"] and event["phase"] == "preview":
                continue
            if previous is not None and (event["attemptID"] < previous["attemptID"]
                    or (event["attemptID"] == previous["attemptID"]
                        and event["observedMS"] <= previous["observedMS"])):
                continue
        previous = event if event["choices"] else None
        yield event


def decisions(row):
    return [e for e in review_events(row) if e["choices"]]


def at_deadline(row):
    if row.get("endMS") is None:
        return None
    choices = []
    for event in review_events(row):
        if event["readyMS"] > row["endMS"] + 600:
            break
        if event["phase"] == "cleared":
            choices = []
        else:
            choices = event["choices"]
    return choices


def summarize(rows, labels):
    # Do not multiply sample denominators by repeated timing measurements.
    primary = [r for r in rows if r["repetition"] == 0]
    known = [r for r in primary if r["label"] in labels]
    unknown = [r for r in primary if r["label"] not in labels]
    first = [decisions(r)[0]["readyMS"] for r in known if decisions(r)]
    correct_latency = [next(e["readyMS"] for e in decisions(r) if r["label"] in e["choices"])
                       - r["endMS"] for r in known if r.get("endMS") is not None
                       and any(r["label"] in e["choices"] for e in decisions(r))]
    late = [decisions(r)[0]["readyMS"] - r["endMS"] for r in known
            if r.get("endMS") is not None and decisions(r)]
    checks = [r for r in known if at_deadline(r) is not None]
    costs = [c["ms"] for r in rows for c in r["costs"]]
    final_costs = [c["ms"] for r in rows for c in r["costs"] if c["phase"] == "completed"]
    sort_changes = [sum(a["choices"][0] != b["choices"][0]
                        for a, b in zip(decisions(r), decisions(r)[1:])) for r in known]
    totals = defaultdict(float)
    for row in rows:
        totals[row["repetition"]] += sum(c["ms"] for c in row["costs"])
    return dict(
        known=len(known), unknown=len(unknown),
        known_with_review=sum(bool(decisions(r)) for r in known),
        any_top1=sum(any(e["choices"][0] == r["label"] for e in decisions(r)) for r in known),
        any_top3=sum(any(r["label"] in e["choices"] for e in decisions(r)) for r in known),
        first_top1=sum(bool(decisions(r)) and decisions(r)[0]["choices"][0] == r["label"] for r in known),
        first_top3=sum(bool(decisions(r)) and r["label"] in decisions(r)[0]["choices"] for r in known),
        deadline_denominator=len(checks),
        deadline_available=sum(bool(at_deadline(r)) for r in checks),
        deadline_top1=sum(bool(at_deadline(r)) and at_deadline(r)[0] == r["label"] for r in checks),
        deadline_top3=sum(r["label"] in at_deadline(r) for r in checks),
        unknown_with_review=sum(bool(decisions(r)) for r in unknown),
        multiple_reviews=sum(len(decisions(r)) > 1 for r in known),
        winner_changes=sum(sort_changes),
        review_events=sum(len(decisions(r)) for r in known),
        ready_from_clip_start_p50_ms=quantile(first, .5),
        ready_from_clip_start_p95_ms=quantile(first, .95),
        ready_vs_motion_end_p50_ms=quantile(late, .5),
        correct_option_vs_motion_end_p50_ms=quantile(correct_latency, .5),
        compute_p50_ms=quantile(costs, .5), compute_p95_ms=quantile(costs, .95),
        completed_compute_p50_ms=quantile(final_costs, .5),
        completed_compute_p95_ms=quantile(final_costs, .95),
        compute_total_median_ms=round(statistics.median(totals.values()), 3),
        calls_per_run=len([c for r in primary for c in r["costs"]]),
        stale=sum(r["stale"] for r in primary), invalidated=sum(r["invalidated"] for r in primary),
        segments=sum(r["segments"] for r in primary), overflows=sum(r["overflows"] for r in primary),
    )


def report(source):
    data = json.loads(source.read_text())
    rows, labels = data["rows"], set(data["labels"])
    grouped = defaultdict(list)
    for row in rows:
        grouped[("all", row["policy"])].append(row)
        grouped[(row["profile"], row["policy"])].append(row)
    summaries = {f"{profile}/{policy}": summarize(group, labels)
                 for (profile, policy), group in grouped.items()}
    target = source.with_suffix(".summary.json")
    target.write_text(json.dumps(dict(scope=data["scope"], summaries=summaries), indent=2))
    print(data["scope"])
    print("Profile / policy | known | available@+600 | top1@+600 | top3@+600 | any top3 | unknown reviews | first ready p50 ms")
    for key, result in summaries.items():
        r = result
        print(f"{key:24s} | {r['known']:3d} | {r['deadline_available']:3d} | {r['deadline_top1']:3d} | "
              f"{r['deadline_top3']:3d} | {r['any_top3']:3d} | {r['unknown_with_review']:3d}/{r['unknown']:3d} | "
              f"{r['ready_from_clip_start_p50_ms']}")
    for policy in dict.fromkeys(r["policy"] for r in rows):
        print(policy, json.dumps(summaries[f"all/{policy}"]))
    print(f"Saved {target}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    report(parser.parse_args().input)
