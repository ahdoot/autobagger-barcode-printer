#!/usr/bin/env python3
"""Resumable PostHero harvester -> JSONL shards.

Pulls posthero_orders from ShipHero's private endpoint, sharded by
(brand x week), with checkpoints so a token expiry never costs the run.

Auth: this endpoint is behind Auth0. Lift the bearer from a logged-in browser
on shipping.shiphero.com (see README.md) and export it:

    export POSTHERO_TOKEN='eyJ...'
    python3 harvest.py --days 60 --outdir ./shards --threads 16

On HTTP 401 the harvester pauses and re-reads POSTHERO_TOKEN from the token
file (--token-file, default ./posthero_token.txt), so you can drop in a fresh
token mid-run without restarting.

Deliberate constraints baked in (do not "optimize" these away):
  * is_3pl=True + from_date + customer_id are ALL required, or total_count=0.
  * first=100 is a hard cap; 200+ returns HTTP 500.
  * No statistics{} block -- with it a 100-row page times out at 30s.
  * Results are sorted by STATUS, not date. Offset 0 is all-undelivered.
    Keep paging. total_count is NOT a usable denominator.
  * Never call from in-page fetch (PostHog wraps window.fetch on that domain).
"""

import argparse
import datetime as dt
import json
import os
import pathlib
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed

ENDPOINT = "https://app-endpoints.shiphero.com/graphql"
PAGE = 100  # hard cap
MAX_OFFSET = 10000  # safety rail; shard finer if you ever hit it

ORDERS_QUERY = """
query P($is3:Boolean,$isf:Boolean,$first:Int,$offset:Int,
        $from:DateTime,$to:DateTime,$cid:Int){
  orders: posthero_orders(is_3pl:$is3, is_fulfillment:$isf,
      first:$first, offset:$offset, from_date:$from, to_date:$to,
      customer_id:$cid){
    edges{node{
      order_number shipped_at delivered_at status
      shipping{ tracking_number shipping_carrier shipping_method to_zip state }
    }}}}
"""

BRANDS_QUERY = """
query B { business_relationships { row_id customer { row_id email } } }
"""


class Token:
    """Thread-safe bearer holder that can be re-lifted from disk on 401."""

    def __init__(self, path):
        self.path = pathlib.Path(path)
        self._lock = threading.Lock()
        self._val = os.environ.get("POSTHERO_TOKEN", "").strip()
        if not self._val:
            self._val = self._from_file()
        if not self._val:
            sys.exit("No token. Set POSTHERO_TOKEN or write %s (see README)." % path)

    def _from_file(self):
        try:
            return self.path.read_text().strip()
        except OSError:
            return ""

    def get(self):
        with self._lock:
            return self._val

    def refresh(self, stale):
        """Re-read the token file. Returns True if we got a different token."""
        with self._lock:
            if self._val != stale:
                return True  # another thread already rotated it
            for _ in range(60):  # wait up to ~5 min for a fresh paste
                new = self._from_file()
                if new and new != stale:
                    self._val = new
                    print("[auth] picked up refreshed token", flush=True)
                    return True
                print("[auth] 401 -- waiting for fresh token in %s" % self.path,
                      flush=True)
                time.sleep(5)
            return False


def gql(token, query, variables, timeout=60):
    body = json.dumps({"query": query, "variables": variables}).encode()
    req = urllib.request.Request(ENDPOINT, data=body, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Authorization", "Bearer " + token.get())
    req.add_header("Accept", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            payload = json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        if e.code == 401:
            raise Unauthorized(token.get())
        raise
    if payload.get("errors"):
        # The validator is verbose: surface it, it tells you the right field.
        raise RuntimeError(json.dumps(payload["errors"])[:1200])
    return payload["data"]


class Unauthorized(Exception):
    def __init__(self, stale):
        super().__init__("401")
        self.stale = stale


def with_auth_retry(token, fn, tries=4):
    delay = 2
    for attempt in range(tries):
        try:
            return fn()
        except Unauthorized as e:
            if not token.refresh(e.stale):
                raise
        except (urllib.error.URLError, TimeoutError, RuntimeError):
            if attempt == tries - 1:
                raise
            time.sleep(delay)
            delay *= 2
    raise RuntimeError("exhausted retries")


def iso(d):
    return d.strftime("%Y-%m-%dT%H:%M:%S")


def week_windows(days, today=None):
    """Split the lookback into 7-day [from, to) windows, oldest first."""
    end = (today or dt.datetime.utcnow()).replace(microsecond=0)
    start = end - dt.timedelta(days=days)
    out, cur = [], start
    while cur < end:
        nxt = min(cur + dt.timedelta(days=7), end)
        out.append((cur, nxt))
        cur = nxt
    return out


def fetch_brands(token):
    data = with_auth_retry(token, lambda: gql(token, BRANDS_QUERY, {}))
    brands = []
    for br in data.get("business_relationships") or []:
        cust = br.get("customer") or {}
        cid = cust.get("row_id")
        if cid:
            brands.append({"customer_id": int(cid),
                           "email": cust.get("email"),
                           "relationship_row_id": br.get("row_id")})
    # dedupe on customer_id
    seen, uniq = set(), []
    for b in brands:
        if b["customer_id"] not in seen:
            seen.add(b["customer_id"])
            uniq.append(b)
    return uniq


def shard_path(outdir, cid, w_from):
    return pathlib.Path(outdir) / ("cid%d_%s.jsonl" % (cid, w_from.strftime("%Y%m%d")))


def harvest_shard(token, cid, w_from, w_to, outdir):
    """Page one (brand x week) shard to completion. Resumable & idempotent."""
    path = shard_path(outdir, cid, w_from)
    done_marker = path.with_suffix(".done")
    if done_marker.exists():
        return ("skip", cid, w_from, sum(1 for _ in path.open())) if path.exists() \
            else ("skip", cid, w_from, 0)

    rows, offset = [], 0
    while offset <= MAX_OFFSET:
        variables = {"is3": True, "isf": None, "first": PAGE, "offset": offset,
                     "from": iso(w_from), "to": iso(w_to), "cid": cid}
        data = with_auth_retry(
            token, lambda v=variables: gql(token, ORDERS_QUERY, v))
        edges = ((data.get("orders") or {}).get("edges")) or []
        if not edges:
            break
        for e in edges:
            node = e.get("node") or {}
            node["_customer_id"] = cid
            node["_week"] = w_from.strftime("%Y-%m-%d")
            rows.append(node)
        if len(edges) < PAGE:
            break
        offset += PAGE

    tmp = path.with_suffix(".jsonl.tmp")
    with tmp.open("w") as fh:
        for r in rows:
            fh.write(json.dumps(r) + "\n")
    tmp.replace(path)
    done_marker.write_text(str(len(rows)))
    return ("ok", cid, w_from, len(rows))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--days", type=int, default=60)
    ap.add_argument("--outdir", default="./shards")
    ap.add_argument("--threads", type=int, default=16)
    ap.add_argument("--token-file", default="./posthero_token.txt")
    ap.add_argument("--customer-ids", default="",
                    help="comma-separated override; default = all brands")
    args = ap.parse_args()

    outdir = pathlib.Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    token = Token(args.token_file)

    if args.customer_ids:
        brands = [{"customer_id": int(x), "email": None}
                  for x in args.customer_ids.split(",") if x.strip()]
    else:
        brands = fetch_brands(token)
        (outdir / "brands.json").write_text(json.dumps(brands, indent=2))
    weeks = week_windows(args.days)
    shards = [(b["customer_id"], wf, wt) for b in brands for wf, wt in weeks]
    print("[plan] %d brands x %d weeks = %d shards"
          % (len(brands), len(weeks), len(shards)), flush=True)

    t0, total, failures = time.time(), 0, []
    per_brand = {}
    with ThreadPoolExecutor(max_workers=args.threads) as pool:
        futs = {pool.submit(harvest_shard, token, cid, wf, wt, outdir): (cid, wf)
                for cid, wf, wt in shards}
        for i, fut in enumerate(as_completed(futs), 1):
            cid, wf = futs[fut]
            try:
                _, _, _, n = fut.result()
                total += n
                per_brand[cid] = per_brand.get(cid, 0) + n
            except Exception as exc:  # keep going; shard stays un-done
                failures.append((cid, wf.strftime("%Y-%m-%d"), str(exc)[:200]))
            if i % 10 == 0 or i == len(shards):
                print("[%d/%d] rows=%d elapsed=%ds"
                      % (i, len(shards), total, time.time() - t0), flush=True)

    (outdir / "harvest_summary.json").write_text(json.dumps(
        {"rows": total, "per_brand": per_brand, "failures": failures,
         "shards": len(shards), "seconds": round(time.time() - t0)}, indent=2))
    print("[done] %d rows in %ds; %d failed shards"
          % (total, time.time() - t0, len(failures)), flush=True)
    if failures:
        print("Re-run to retry failed shards (completed ones are skipped).")


if __name__ == "__main__":
    main()
