#!/usr/bin/env python3
"""Ground time-in-transit histograms from harvested PostHero shards.

    python3 analyze.py --shards ./shards --out ./out

Measures shipped_at -> delivered_at. That is CARRIER TRANSIT ONLY; it excludes
pre-ship queue time and is NOT order-to-door.
"""

import argparse
import collections
import datetime as dt
import json
import pathlib

from ground_methods import classify
from holidays import business_days

MAX_DAYS = 45  # anything beyond this is bad data


def parse_ts(s):
    if not s:
        return None
    s = str(s).strip().replace("Z", "+00:00")
    try:
        d = dt.datetime.fromisoformat(s)
    except ValueError:
        for fmt in ("%Y-%m-%d %H:%M:%S", "%Y-%m-%dT%H:%M:%S.%f",
                    "%Y-%m-%dT%H:%M:%S", "%Y-%m-%d"):
            try:
                d = dt.datetime.strptime(s[:26], fmt)
                break
            except ValueError:
                continue
        else:
            return None
    return d.replace(tzinfo=None)


def load_rows(shards):
    for p in sorted(pathlib.Path(shards).glob("*.jsonl")):
        with p.open() as fh:
            for line in fh:
                line = line.strip()
                if line:
                    try:
                        yield json.loads(line)
                    except json.JSONDecodeError:
                        continue


def pct(sorted_vals, q):
    if not sorted_vals:
        return None
    if len(sorted_vals) == 1:
        return float(sorted_vals[0])
    k = q * (len(sorted_vals) - 1)
    lo, hi = int(k), min(int(k) + 1, len(sorted_vals) - 1)
    return round(sorted_vals[lo] + (sorted_vals[hi] - sorted_vals[lo]) * (k - lo), 2)


def stats(vals):
    v = sorted(vals)
    if not v:
        return {"n": 0}
    return {"n": len(v), "mean": round(sum(v) / len(v), 2),
            "p50": pct(v, .50), "p90": pct(v, .90), "p95": pct(v, .95),
            "min": v[0], "max": v[-1]}


def histogram(vals, cap=21):
    h = collections.Counter()
    for v in vals:
        h[min(int(v), cap)] += 1
    return {str(k): h[k] for k in sorted(h)}


def build(shards):
    seen = set()
    recs, undelivered, dropped, unclassified = [], [], collections.Counter(), collections.Counter()
    total = 0

    for row in load_rows(shards):
        total += 1
        ship = row.get("shipping") or {}
        key = (row.get("order_number"), ship.get("tracking_number"))
        if key in seen:
            dropped["duplicate"] += 1
            continue
        seen.add(key)

        carrier = ship.get("shipping_carrier")
        method = ship.get("shipping_method")
        kind = classify(carrier, method)
        if kind == "unclassified":
            unclassified["%s | %s" % (carrier, method)] += 1
            continue
        if kind == "air":
            dropped["air"] += 1
            continue

        s, d = parse_ts(row.get("shipped_at")), parse_ts(row.get("delivered_at"))
        if not s:
            dropped["no_shipped_at"] += 1
            continue
        if not d:
            undelivered.append({"carrier": carrier, "method": method,
                                "status": row.get("status")})
            continue

        cal = (d.date() - s.date()).days
        if cal < 0:
            dropped["negative"] += 1
            continue
        if cal > MAX_DAYS:
            dropped["over_%dd" % MAX_DAYS] += 1
            continue

        recs.append({"carrier": carrier, "method": method, "kind": kind,
                     "cal": cal, "biz": business_days(s, d),
                     "state": ship.get("state"), "zip": ship.get("to_zip")})

    return {"records": recs, "undelivered": undelivered, "dropped": dict(dropped),
            "unclassified": dict(unclassified.most_common()), "rows_read": total}


def summarize(recs, label):
    return {
        "scope": label,
        "business_days": {**stats([r["biz"] for r in recs]),
                          "histogram": histogram([r["biz"] for r in recs])},
        "calendar_days": {**stats([r["cal"] for r in recs]),
                          "histogram": histogram([r["cal"] for r in recs])},
    }


def report(data, include_soft=True):
    recs = [r for r in data["records"]
            if include_soft or r["kind"] == "ground"]
    by_carrier = collections.defaultdict(list)
    for r in recs:
        by_carrier[r["carrier"] or "(unknown)"].append(r)

    undel_by_carrier = collections.Counter(
        u["carrier"] or "(unknown)" for u in data["undelivered"])
    n_undel = len(data["undelivered"])
    denom = len(recs) + n_undel

    return {
        "basis": "shipped_at -> delivered_at (carrier transit only; "
                 "excludes pre-ship queue time; NOT order-to-door)",
        "soft_ground_included": include_soft,
        "overall": summarize(recs, "all ground carriers"),
        "per_carrier": {
            c: {**summarize(rs, c),
                "undelivered_in_window": undel_by_carrier.get(c, 0)}
            for c, rs in sorted(by_carrier.items(), key=lambda kv: -len(kv[1]))
        },
        "undelivered": {
            "count": n_undel,
            "share_of_ground_shipments": round(n_undel / denom, 4) if denom else 0,
            "by_carrier": dict(undel_by_carrier.most_common()),
            "note": "Excluded from percentiles. The slowest shipments are the "
                    "likeliest to still be undelivered, so p90/p95 are OPTIMISTIC.",
        },
        "unclassified_methods": data["unclassified"],
        "dropped": data["dropped"],
        "rows_read": data["rows_read"],
        "caveats": [
            "Transit is shipped_at -> delivered_at: carrier transit only, not "
            "order-to-door. Pre-ship queue time is excluded.",
            "Bucketing on delivery drops everything still in transit. Slow "
            "shipments are over-represented among the undelivered, so p90/p95 "
            "understate the true tail. See undelivered.count.",
            "Carrier mix is confounded with geography, weight, and brand. A "
            "carrier that looks faster here is NOT like-for-like; a real "
            "comparison needs zone-matched lanes.",
        ],
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--shards", default="./shards")
    ap.add_argument("--out", default="./out")
    args = ap.parse_args()

    out = pathlib.Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    data = build(args.shards)

    full = report(data, include_soft=True)
    hard = report(data, include_soft=False)
    (out / "transit_report.json").write_text(json.dumps(full, indent=2))
    (out / "transit_report_hard_ground_only.json").write_text(
        json.dumps(hard, indent=2))

    o = full["overall"]
    print("rows read: %d | delivered ground: %d | undelivered: %d (%.1f%%)"
          % (full["rows_read"], o["business_days"]["n"],
             full["undelivered"]["count"],
             100 * full["undelivered"]["share_of_ground_shipments"]))
    for lbl in ("business_days", "calendar_days"):
        s = o[lbl]
        print("%-14s n=%s mean=%s p50=%s p90=%s p95=%s"
              % (lbl, s["n"], s.get("mean"), s.get("p50"), s.get("p90"), s.get("p95")))
    if full["unclassified_methods"]:
        print("UNCLASSIFIED (carrier | method) -- add to ground_methods.py:")
        for k, v in full["unclassified_methods"].items():
            print("  %6d  %s" % (v, k))
    print("wrote %s" % (out / "transit_report.json"))


if __name__ == "__main__":
    main()
