// POST /api/reset  body: { mode: 'auto' | 'all', pin? }
//
// Puts the training station back to a clean state.
//
//   mode 'auto' (the page runs it on load): only training orders a picker has
//   actually touched — something was picked into a tote, or the order is
//   locked — and that have been idle for IDLE_MINUTES+. Their totes are cleared
//   (ShipHero puts the units back in the bins) and the orders are cancelled.
//   Untouched orders are left alone so the next trainee can pick them.
//
//   mode 'all' (Reset button): every open training order, touched or not.
//
// Safety: only SHIPBOTS orders named TEST-TRAINING-### or TRN-####-XXXX are
// ever cancelled, and a tote is cleared only if every order in it is one.

const { SHIPBOTS_ACCOUNT_ID } = require('./_catalog');
const { API, accessToken, resetToken } = require('./_auth');

const IDLE_MINUTES = 30;
const LOOKBACK_DAYS = 30;
const TRAINING = /^(TEST-TRAINING-\d+|TRN-\d{4}-[A-Z0-9]{4})$/;

const OPEN_ORDERS = `query OpenTraining($acct: String, $from: ISODateTime, $to: ISODateTime) {
  orders(customer_account_id: $acct, shop_name: "Picker Training", order_date_from: $from, order_date_to: $to,
         fulfillment_status_not_in: ["canceled", "cancelled", "fulfilled"]) {
    data(first: 100, sort: "-order_date") { edges { node {
      id order_number account_id fulfillment_status updated_at
      allocations { is_locked allocated_at }
      line_items(first: 10) { edges { node { tote_picks { tote_id picked_quantity updated_at } } } }
    } } }
  }
}`;
const TOTE = `query TrainingTote($id: String) {
  tote(id: $id) { data { id name status last_activity orders { id order_number account_id fulfillment_status } } }
}`;
const CLEAR = `mutation ClearTote($data: ClearToteInput!) { tote_clear(data: $data) { request_id ok } }`;
const CANCEL = `mutation CancelTraining($data: CancelOrderInput!) { order_cancel(data: $data) { request_id order { order_number fulfillment_status } } }`;

async function gql(token, query, variables) {
  const r = await fetch(`${API}/graphql`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    body: JSON.stringify({ query, variables }),
  });
  if (r.status === 401) resetToken();
  const body = await r.json().catch(() => ({}));
  if (!r.ok || (body.errors && body.errors.length)) {
    throw new Error((body.errors && body.errors[0] && body.errors[0].message) || `ShipHero returned ${r.status}.`);
  }
  return body.data;
}

const isTraining = (o) => o && o.account_id === SHIPBOTS_ACCOUNT_ID && TRAINING.test(o.order_number || '');
const ts = (s) => (s ? new Date(s).getTime() || 0 : 0);

// What a picker has done with an order, from ShipHero's point of view.
function activity(o) {
  const picks = [];
  for (const e of (o.line_items && o.line_items.edges) || []) {
    for (const p of (e.node && e.node.tote_picks) || []) if (p.picked_quantity > 0 && p.tote_id) picks.push(p);
  }
  const locked = (o.allocations || []).some((a) => a && a.is_locked);
  const last = Math.max(0, ...picks.map((p) => ts(p.updated_at)), locked ? ts(o.updated_at) : 0);
  return { picked: picks.length > 0, locked, toteIds: [...new Set(picks.map((p) => p.tote_id))], last };
}

module.exports = async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  if (req.method !== 'POST') { res.setHeader('Allow', 'POST'); return res.status(405).json({ error: 'POST only' }); }
  const body = typeof req.body === 'string' ? JSON.parse(req.body || '{}') : (req.body || {});
  const pin = process.env.TRAINING_PIN;
  if (pin && String(body.pin || '') !== pin) return res.status(401).json({ error: 'Wrong PIN.' });
  const mode = body.mode === 'all' ? 'all' : 'auto';

  let token;
  try { token = await accessToken(); } catch (e) { return res.status(503).json({ error: e.message }); }

  const cleared = [], cancelled = [], untouched = [], skipped = [], errors = [];
  try {
    const to = new Date(), from = new Date(to.getTime() - LOOKBACK_DAYS * 24 * 3600 * 1000);
    const open = (await gql(token, OPEN_ORDERS, { acct: SHIPBOTS_ACCOUNT_ID, from: from.toISOString(), to: to.toISOString() }))
      .orders.data.edges.map((e) => e.node).filter(isTraining);
    const cutoff = Date.now() - IDLE_MINUTES * 60 * 1000;

    // 1. Decide which orders to reset.
    const targets = [];
    for (const o of open) {
      const a = activity(o);
      if (mode === 'auto') {
        if (!a.picked && !a.locked) { untouched.push(o.order_number); continue; } // nobody started it: leave it
        if (a.last > cutoff) { skipped.push(o.order_number); continue; } // still being picked
      }
      targets.push({ ...o, ...a });
    }

    // 2. Clear their totes (one tote can hold several training orders; a tote with
    //    a real customer order in it is never touched).
    const toteIds = [...new Set(targets.flatMap((t) => t.toteIds))];
    const badTotes = new Set();
    for (const id of toteIds) {
      try {
        const t = (await gql(token, TOTE, { id })).tote.data;
        if (!t) continue; // already emptied
        const orders = t.orders || [];
        if (orders.length && !orders.every(isTraining)) { badTotes.add(id); errors.push(`${t.name}: holds a non-training order, left alone`); continue; }
        if (mode === 'auto' && ts(t.last_activity) > cutoff) { badTotes.add(id); continue; } // still in use
        if (t.status === 'Empty') continue;
        const out = await gql(token, CLEAR, { data: { tote_id: id, return_inventory: true } });
        if (!out.tote_clear || out.tote_clear.ok === false) throw new Error('tote_clear returned ok=false');
        cleared.push(t.name);
      } catch (e) {
        badTotes.add(id);
        errors.push(`tote ${id}: ${e.message}`);
      }
    }

    // 3. Cancel the orders (skipping any whose tote could not be cleared).
    for (const t of targets) {
      if (t.toteIds.some((id) => badTotes.has(id))) { skipped.push(t.order_number); continue; }
      try {
        await gql(token, CANCEL, { data: { customer_account_id: SHIPBOTS_ACCOUNT_ID, order_id: t.id, reason: 'Training station reset', cancel_on_platform: false } });
        cancelled.push(t.order_number);
      } catch (e) {
        errors.push(`${t.order_number}: ${e.message}`);
      }
    }
  } catch (e) {
    return res.status(502).json({ error: e.message, cleared, cancelled, errors });
  }
  return res.status(200).json({ mode, cleared, cancelled, untouched, skipped, errors });
};
