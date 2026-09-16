# PostHero ground time-in-transit 📦

Histograms of **carrier transit time** (`shipped_at` → `delivered_at`) for
ground methods across all brands. Not order-to-door — pre-ship queue time is
excluded.

## Why this route

Delivery timestamps live **only** in PostHero (`posthero_orders`). Dead ends,
confirmed: the public API/MCP and the private orders query return
`delivered: null`; `shipping_labels.delivered` is always null;
`tracking_data.tracking_status.status` has status but no timestamp; the UI
Shipments export has no delivery-date column at all.

Confirm PostHero is enabled on the account (shipping.shiphero.com/posthero/)
before running.

## 1. Lift the bearer token

**Do not call the endpoint from an in-page fetch** — PostHog's session
recorder wraps `window.fetch` on that domain and sustained requests die with
`Failed to fetch`. Lift the token and call from Python.

In the browser console on `shipping.shiphero.com`:

```js
copy(Object.keys(localStorage)
  .filter(k => k.includes('@@auth0spajs@@') && k.includes('app-endpoints'))
  .map(k => JSON.parse(localStorage[k]).body.access_token)[0])
```

Paste it into `posthero_token.txt` (the harvester re-reads this file on HTTP
401, so a mid-run expiry costs you nothing — just paste a fresh one).

## 2. Harvest

```bash
echo '<token>' > posthero_token.txt
python3 harvest.py --days 60 --threads 16 --outdir ./shards
```

Sharded by **(brand × week)** — each shard is an independent offset space,
which also dodges the deep-offset slowdown. Resumable: completed shards write
a `.done` marker and are skipped on re-run. For scale, 23 brands × 9 weeks =
207 shards ≈ 443k rows in ~22 min at 16 threads.

Reconcile `harvest_summary.json` → `per_brand` against expectations. A
shortfall means shard finer (split to half-weeks), **not** missing data.
`total_count` is not a usable denominator — it lies.

### Constraints baked into the harvester — don't "optimize" them away

| Trap | Reality |
|---|---|
| Required filters | `is_3pl:true` + `from_date` + `customer_id` all required, or you get `total_count: 0` — not an error. Empty ⇒ wrong filters. |
| `state:` filter | Always returns 0. Pull everything, bucket client-side on status. |
| `first` | 100 is a hard cap; 200+ → instant HTTP 500. |
| `statistics{}` | Omitted. With it a 100-row page times out at 30s; without it, ~1s. |
| Sort order | Sorted by **status**, not date. Offset 0 is 100% undelivered rows — a first-page sample looks like there's no delivery data. Keep paging. |

Introspection is disabled, but the validator is verbose — guess a field and it
suggests the right one.

## 3. Analyze

```bash
python3 analyze.py --shards ./shards --out ./out
```

Writes `transit_report.json` and `transit_report_hard_ground_only.json`
(soft-ground sensitivity test). Dedupes on `(order_number, tracking_number)`;
drops negatives and anything over 45 days as bad data. Business days are
Mon–Fri excluding US federal holidays, same-day = 0.

## Ground vs air

`ground_methods.py` is an explicit **(carrier, method) allowlist**. Substring
matching on "Ground" is wrong in both directions:

- **Ground but not named so:** USPS First Class Mail (surface since 2021),
  FedEx SmartPost, UPS SurePost, UniUni GROUND, GOFO Parcel Pickup, DHL
  SmartMail Parcel Ground, DHL Parcel Expedited / Expedited Max (DHL eCommerce
  is ground injection — "Expedited" is a service tier, not air).
- **Named ground-ish, actually air/deferred-air:** UPS 3 Day Select, FedEx
  Express Saver.

Anything unrecognized lands in an `unclassified` bucket that is **counted and
reported**, never defaulted either way — new method strings appear mid-harvest.
`analyze.py` prints them; add them to the allowlist and re-run.

USPS First Class Mail / SmartPost / SurePost are tagged `ground_soft` so they
can be sensitivity-tested out.

## Report these caveats alongside the numbers — don't bury them

1. **p90/p95 are optimistic.** Bucketing on delivery drops everything still in
   transit (~13% on a 60-day window), and the slowest shipments are the
   likeliest to be undelivered. `undelivered.count` sits next to the
   percentiles in the report for exactly this reason.
2. **Carrier mix is confounded** with geography, weight, and brand. A carrier
   that looks faster is not like-for-like — a real comparison needs
   zone-matched lanes.
