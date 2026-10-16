// POST /api/reset  body: { mode: 'auto' | 'all', pin? }
//
// Puts the training station back to a clean state:
//   1. Clears every tote that holds ONLY training orders (ShipHero returns the
//      picked units to their bins), then cancels those orders.
//   2. mode 'all' also cancels every other open training order.
//   mode 'auto' only touches totes idle for IDLE_MINUTES+, so an active session
//   is never interrupted. The page calls it on load.
//
// Safety: a tote is touched only if every order in it belongs to the SHIPBOTS
// account and is named TEST-TRAINING-### or TRN-####-XXXX.

const { SHIPBOTS_ACCOUNT_ID } = require('./_catalog');
const { API, accessToken, resetToken } = require('./_auth');

const WAREHOUSE_ID = 'V2FyZWhvdXNlOjc0Nzc2'; // Primary (Gardena)
const IDLE_MINUTES = 30;
const TRAINING = /^(TEST-TRAINING-\d+|TRN-\d{4}-[A-Z0-9]{4})$/;
const DONE = /cancel|fulfilled/i;

const TOTES = `query TrainingTotes($wh: [String]) {
  totes(warehouse_ids: $wh, status: ["Stocked"]) {
    data(first: 100) { edges { node {
      id name last_activity
      orders { id order_number account_id fulfillment_status }
    } } }
  }
}`;
const OPEN_ORDERS = `query OpenTraining($acct: String, $from: ISODateTime, $to: ISODateTime) {
  orders(customer_account_id: $acct, shop_name: "Picker Training", order_date_from: $from, order_date_to: $to) {
    data(first: 100, sort: "-order_date") { edges { node { id order_number fulfillment_status } } }
  }
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

module.exports = async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  if (req.method !== 'POST') { res.setHeader('Allow', 'POST'); return res.status(405).json({ error: 'POST only' }); }
  const body = typeof req.body === 'string' ? JSON.parse(req.body || '{}') : (req.body || {});
  const pin = process.env.TRAINING_PIN;
  if (pin && String(body.pin || '') !== pin) return res.status(401).json({ error: 'Wrong PIN.' });
  const mode = body.mode === 'all' ? 'all' : 'auto';

  let token;
  try { token = await accessToken(); } catch (e) { return res.status(503).json({ error: e.message }); }

  const cleared = [], cancelled = [], errors = [];
  const toCancel = new Map(); // order id -> order_number
  try {
    const totes = (await gql(token, TOTES, { wh: [WAREHOUSE_ID] })).totes.data.edges.map((e) => e.node);
    const cutoff = Date.now() - IDLE_MINUTES * 60 * 1000;
    for (const t of totes) {
      const orders = t.orders || [];
      if (!orders.length || !orders.every(isTraining)) continue; // never touch a real tote
      if (mode === 'auto' && new Date(t.last_activity).getTime() > cutoff) continue; // still in use
      try {
        const out = await gql(token, CLEAR, { data: { tote_id: t.id, return_inventory: true } });
        if (!out.tote_clear || out.tote_clear.ok === false) throw new Error('tote_clear returned ok=false');
        cleared.push(t.name);
        orders.forEach((o) => { if (!DONE.test(o.fulfillment_status || '')) toCancel.set(o.id, o.order_number); });
      } catch (e) {
        errors.push(`${t.name}: ${e.message}`);
      }
    }

    if (mode === 'all') {
      const to = new Date(), from = new Date(to.getTime() - 365 * 24 * 3600 * 1000);
      const open = (await gql(token, OPEN_ORDERS, { acct: SHIPBOTS_ACCOUNT_ID, from: from.toISOString(), to: to.toISOString() }))
        .orders.data.edges.map((e) => e.node)
        .filter((o) => TRAINING.test(o.order_number || '') && !DONE.test(o.fulfillment_status || ''));
      open.forEach((o) => toCancel.set(o.id, o.order_number));
    }

    for (const [id, number] of toCancel) {
      try {
        await gql(token, CANCEL, { data: { customer_account_id: SHIPBOTS_ACCOUNT_ID, order_id: id, reason: 'Training station reset', cancel_on_platform: false } });
        cancelled.push(number);
      } catch (e) {
        errors.push(`${number}: ${e.message}`);
      }
    }
  } catch (e) {
    return res.status(502).json({ error: e.message, cleared, cancelled, errors });
  }
  return res.status(200).json({ mode, cleared, cancelled, errors });
};
