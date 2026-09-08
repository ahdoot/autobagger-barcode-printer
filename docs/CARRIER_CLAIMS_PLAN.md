# ShipBots Carrier Claims — Build Plan

Status: **draft for review** · Date: 2026-09-08 · Target: standalone Next.js app on Vercel (separate repo)

A claims-recovery system for ShipBots: detect claim-eligible shipments (lost, delivered-not-received,
damaged, missing contents), file them with the carrier, track them to resolution, and credit the brand.
Modeled on the Mountainy 3PL claims dashboard (total claims / claim amount / recovered / recovery rate,
filtered by date range, carrier, client, searchable by claim #, order ID, tracking).

---

## 1. What the warehouse says (sbsql, last 12 months)

Volume: **~1.12M valid labels**, **$13.5M label cost**, **125–140 active clients/month**, peaking at
~125K labels/month (Dec 2025, Aug 2026). Ship-from: 1715 W Rosecrans Ave, Gardena CA (primary) and
1789 Egbert Ave, San Francisco.

### Carrier mix

| Carrier (ShipHero `carrier_id`) | Labels | Share | Label cost | Claim channel today |
|---|---:|---:|---:|---|
| **FedEx** (3, plus FIC 56, manual 15/16) | 658,896 | 59% | $8.56M | fedex.com Claims portal (online form, batch upload). No public REST claims API. |
| **USPS via Endicia** (2) | 421,405 | 38% | $2.37M | usps.com Claims. Ground Advantage / Priority include $100 insurance. No claims API. |
| **GOFO** (66, since Jun 2026) | 28,545 | 2.6% | $110K | Regional carrier, email/portal per contract. |
| UPS | 281 | <0.1% | third-party labels | Negligible. UPS has a Claims API if ever needed. |
| UniUni, Global-e, APC/FlavorCloud, OSM, GLS, DHL | <600 | | | Out of scope v1. |
| Generic / manual labels | 7,854 | 0.7% | $0 | Client's own label — not ShipBots' claim to file. |

FedEx services: Ground Economy/SmartPost 332K · Ground 191K · Home Delivery 52K · Intl Connect Plus 49K ·
2Day 28K · Intl Economy 2.2K · Standard Overnight 1.6K · Express Saver 0.4K · Intl Priority 0.3K.
USPS services: Ground Advantage 388K · Priority 18K · First Class 11K · Media Mail 4.3K.

Declared value: FedEx has `insurance_amount > 0` on only 6,414 labels (avg $453). USPS has none.
So nearly every claim today caps at the carrier's $100 default liability plus shipping.

Order values behind those labels: USPS avg order $87 with 108K orders over $100; FedEx avg $1,424
(skewed by wholesale; 70K orders over $500).

### How claims are handled today (QuickBooks)

Claims are credited to brands as negative invoice lines, with the order numbers and per-order credit
typed into the line description by hand:

| Year | Item | Lines | Credited | Clients |
|---|---|---:|---:|---:|
| 2024 | FedEx Claims Reimbursement | 36 | $8.5K | 18 |
| 2025 | FedEx Claims Reimbursement | 148 | $51.3K | 42 |
| 2026 YTD | FedEx Claims Reimbursement | 156 | $41.9K | 54 |
| 2025 | USPS Claims Reimbursement | 5 | $522 | 4 |
| 2026 YTD | USPS Claims Reimbursement | 2 | $141 | 2 |
| 2025 / 2026 YTD | Reimbursement (generic ops credits) | 95 / 62 | $45.3K / $37.4K | 48 / 35 |

Typical description: `FedEx Claims Reimbursement / 46602 Credit -$109.38 / 43103 Credit -$106.68 …`
— almost every credit is $100 + label cost, i.e. a FedEx lost-package claim at default liability.

Top recipients since 2025: Wired EBIKES $21.7K, COMPLEX (Ntwrk) $13.1K, DONNI $7.4K, +44 Plus $5.3K,
Kidoriman $4.2K, Superspace $3.7K, Boldr $3.5K, Kinobody $2.9K.

### What that tells us

1. FedEx claims are being filed and paid (~$50K/yr) but tracked only in invoice text. No status,
   no deadlines, no per-claim history, no brand visibility.
2. **USPS is untouched**: 421K labels/yr carrying $100 included insurance, 7 claims in 20 months.
3. Nothing in the warehouse records tracking/delivery events, so lost and stalled packages can only be
   found today when a brand complains. Returns rarely carry a Damaged (10) or Shipping Error (71) flag.
4. `billing_usps` has no rows in the last 12 months (stale feed). `billing_fedex` is live and itemized
   (fuel, discounts, duties) — useful later for invoice audits.

### Opportunity (rule of thumb, verify against DNR ticket volume)

Industry lost/damaged rates run ~0.3–0.5% of parcels. On 1.12M parcels that is 3,400–5,600 eligible
events/yr. At ~$100–110 each that is **$340K–$600K claimable vs ~$95K credited today**.

---

## 2. Carrier claim rules (the eligibility engine)

Encoded as data (`rules` table), not code, so they can be tuned per carrier/service/contract.

| Carrier · claim type | Earliest file | Latest file | Default liability | Evidence |
|---|---|---|---|---|
| FedEx · lost / non-delivery (US) | after trace / no scan ≥ 7 days | 9 months from ship date | $100 unless declared value | tracking, invoice/proof of value, recipient statement |
| FedEx · damage / missing contents (US) | immediately | 60 days from delivery | $100 unless declared value | photos (item + packaging), invoice; keep packaging for inspection |
| FedEx · international (Intl Connect Plus, Economy, Priority) | immediately | 21 days from delivery (damage); verify loss window per contract | per service | as above + commercial invoice |
| FedEx · late delivery (Money-Back Guarantee) | on delivery | 15 days from invoice date | full freight refund | Express services only; Ground/Home/Ground Economy MBG suspended — Phase 4 |
| USPS · Ground Advantage lost | 15 days after mailing | 60 days | $100 included | label, proof of value |
| USPS · Ground Advantage damaged | immediately | 60 days | $100 included | photos, proof of value |
| USPS · Priority Mail lost/damaged | 15 days (lost) / 0 (damage) | 60 days | $100 included | as above |
| USPS · Priority Mail Express | 7 days | 60 days | $100 included | as above |
| USPS · First Class, Media Mail | — | — | none unless purchased | not claimable |
| GOFO | per contract (assume 30 days) | per contract | per contract | TBD with GOFO |

Detection triggers:

- **LOST**: past expected delivery and no scan movement for N days (FedEx 7, USPS 7; "arriving late" >10).
- **DNR** (delivered, not received): delivered scan + brand/CS report; enforce carrier wait (5–7 days)
  before filing; pull FedEx photo proof of delivery to triage.
- **DAMAGED / MISSING CONTENTS**: brand/CS report with photos, or return item condition = Damaged.
- **LATE** (MBG, Phase 4): delivered after commitment on Express services.
- **BILLING** (Phase 4): `billing_fedex` vs label — duplicate charges, DIM disputes, residential/address
  correction surcharges on commercial addresses.

---

## 3. Product scope

**Users**: claims agent, account manager, finance, admin (ShipBots); brand user (client portal, Phase 3).

**Screens** (dark-first ops UI like the reference dashboard):

1. **Dashboard** — Total claims · Claim amount · Recovered · Recovery rate, each vs previous period.
   Secondary: open claims, aging, pending at carrier, awaiting credit, deadline-at-risk. Filters: date
   range, carrier, client. Charts: claims/month by carrier, recovery funnel, top clients, by claim type.
2. **Claims list** — table with status pill, carrier, client, type, amount, filed date, deadline,
   days open, assignee; saved views; bulk file/export; CSV export. Global search by claim #, order #,
   tracking #.
3. **Claim detail** — shipment facts auto-pulled from the warehouse (order, tracking, carrier, service,
   ship date, label cost, declared value, destination, line items + values), timeline, evidence,
   carrier claim #, decision + amounts, payout link, client credit link, notes, AI-drafted narrative.
4. **Intake** — web form (tracking # or order # → autofill), Slack `/claim`, CSV bulk, client portal,
   and the **Suggested claims** queue from auto-detection.
5. **Filing workbench** — per-carrier queue. FedEx: batch-claim CSV export in FedEx's template +
   evidence bundle zip. USPS: one-click prefill (copy block + deep link). GOFO: email template.
   Mark filed → capture carrier claim #.
6. **Money** — carrier payouts (import FedEx remittance / USPS checks, allocate to claims) and client
   credits (generate QuickBooks invoice line `FedEx Claims Reimbursement` / `USPS Claims Reimbursement`
   with the same per-order description format finance uses today, or a credit memo).
7. **Client portal** (Phase 3) — brand sees claims, statuses, credits; submits claims; monthly statement.
8. **Settings** — carriers (accounts, rules, caps), clients (fee %, credit method, Slack channel,
   notification prefs), users/roles, rule editor, audit log.

**Slack workflow**: `/claim <tracking or order #>` opens a modal (type, description, photo links) →
claim created → card posted to `#claims` with Approve-to-file / Reject buttons → every status change
threads back. Optional sanitized updates to per-client Slack Connect channels.

**AI (Claude)**: draft carrier narrative + evidence checklist per claim; parse carrier decision emails
and PDFs into status + amounts; check evidence completeness (photos, invoice) before filing; weekly
digest per account manager.

**Claim lifecycle**

```
DETECTED → DRAFT → READY → FILED → CARRIER_REVIEW ⇄ INFO_REQUESTED
        → APPROVED | PARTIAL | DENIED (→ APPEALED → CARRIER_REVIEW)
        → PAID → CREDITED → CLOSED       side exits: WITHDRAWN, EXPIRED
```

---

## 4. Architecture (Vercel)

| Layer | Choice | Notes |
|---|---|---|
| App | Next.js 15 (App Router), TypeScript, Tailwind v4, shadcn/ui, TanStack Table, Recharts | Dark-first theme |
| Database | Neon Postgres + Drizzle ORM | Owns claims, evidence, credits, rules, mirror of shipments |
| Warehouse feed | Hourly sync from `sbsql` (SQL Server) → Neon `shipments` mirror (last 90–180 days of `de_shipping_labels` + `de_orders` + `de_line_items`) | Decouples app from SQL Server reachability; see Decision 1 |
| Auth | Clerk — Google SSO for staff, org + magic link for brands | Roles: admin, claims_agent, account_mgr, finance, client |
| Jobs | Vercel Cron → Inngest functions | tracking polls, deadline scans, sync, digests, retries |
| Files | Vercel Blob | photos, invoices, carrier PDFs, evidence bundles |
| Carrier APIs | FedEx Track API (REST OAuth, 30 tracking #s/call) · USPS Tracking API v3 · GOFO tracking (verify) · optional UPS Claims API | Poll only at-risk shipments, not all 110K/month |
| Email | Resend outbound; inbound mailbox (Resend/Postmark) for carrier claim emails → AI parse | claims@ mailbox |
| Slack | Bolt for JS, HTTP receiver in route handlers | `/claim`, interactivity, events |
| QuickBooks | QBO API (OAuth2) — invoice line or credit memo | reuse existing Pipedream QB connection or direct |
| AI | Anthropic SDK, structured outputs | narrative, email/PDF parsing, evidence check |
| Ops | Sentry, Vercel Analytics, `audit_log` table | |

Data model (Postgres): `clients`, `carriers`, `rules`, `shipments` (mirror), `tracking_events`, `claims`,
`claim_events`, `evidence`, `payouts` + `payout_allocations`, `credits`, `users`, `audit_log`.

Key `claims` columns: `claim_number` (CLM-2026-000123), `shipment_id`, `client_id`, `carrier_code`,
`type`, `status`, `reason`, `merchandise_value`, `shipping_cost`, `requested_amount`, `approved_amount`,
`paid_amount`, `carrier_claim_number`, `filed_at`, `decision_at`, `paid_at`, `deadline_at`, `assignee_id`,
`source` (slack | web | auto | csv | portal), `ai_summary`.

---

## 5. Phases

| Phase | Weeks | Deliverables |
|---|---|---|
| **0 · Foundation** | 1 | New repo, Next + Neon + Clerk + Drizzle, sbsql sync, carrier/rule seed, **backfill ~630 historical credits from QB descriptions** (order # + amount) so the dashboard has 2024–26 history |
| **1 · MVP** | 2–4 | Claims CRUD + status machine, web + Slack intake, claim detail, dashboard KPIs, FedEx batch CSV + USPS prefill, evidence uploads, credits → QuickBooks line, notifications. Ship to the claims team. |
| **2 · Detection** | 5–7 | FedEx Track + USPS tracking polling, lost/stalled detector, deadline engine + alerts, inbound email parsing (AI), Suggested-claims queue, DNR wait logic, GOFO template |
| **3 · Brands & money** | 8–10 | Client portal, monthly claims statement, Slack Connect updates, payout reconciliation (FedEx remittance import), per-client recovery reporting, fee model |
| **4 · Expand** | later | MBG late-delivery refunds (Express), FedEx invoice audit (`billing_fedex` vs label), UPS Claims API, photo POD retrieval, Shopify/Gorgias ticket intake |

---

## 6. Decisions needed

1. **Warehouse access** — allow Vercel egress to `sbsql` (needs static IPs / Secure Compute) vs. a
   push-sync job. *Recommend push-sync hourly into Neon.*
2. **Claim value basis** — keep $100 default + shipping (today's practice), or file declared value where
   set, and/or start declaring value on orders >$100 (a separate margin conversation).
3. **Fee model** — 100% pass-through (Mountainy's stance) vs. % of recovery. *Plan assumes pass-through
   with a configurable `fee_pct` per client.*
4. **Credit method** — keep invoice-line credits (item `FedEx Claims Reimbursement`) vs. QB credit memos.
   *Plan defaults to invoice line so finance's workflow doesn't change.*
5. **Slack scope v1** — internal `#claims` only, or per-client Slack Connect too.
6. **Client portal timing** — Phase 3 as planned, or pull into MVP.
7. **Today's process** — who files, which FedEx logins, where the open-claims spreadsheet lives (to backfill
   in-flight claims), and how FedEx pays out (EFT vs check) for reconciliation.
8. **GOFO** — get their claims procedure and liability terms.

## 7. Risks

- No FedEx/USPS claims API → filing stays semi-manual. Mitigation: batch CSV + prefill + evidence bundles;
  later a browser extension. Re-evaluate FedEx EDI claims at volume.
- Tracking API quotas/cost. Mitigation: poll only shipments past expected delivery, batch requests.
- DNR claims are often denied without evidence. Mitigation: photo POD triage, recipient statements, set
  brand expectations in the portal.
- $100 liability cap vs. order value. The win is volume and USPS coverage, not big-ticket claims.
- QuickBooks writes touch invoicing. Finance sign-off before Phase 1 go-live.
