// POST /api/create-orders
// Body: { pin?: string, orders: [ { lines: [ { sku, qty } ] } ] }
// Creates pending ShipHero orders in the SHIPBOTS child account for picker training.
//
// Env vars (set in Vercel):
//   SHIPHERO_REFRESH_TOKEN                 ShipHero Public API refresh token (3PL user with order write access)
//   SHIPHERO_USERNAME / SHIPHERO_PASSWORD  optional fallback login if the refresh token stops working
//   TRAINING_PIN                           optional; when set, requests must send the same pin

const { SHIPBOTS_ACCOUNT_ID, PRODUCTS, SHIP_TO, FIRST_NAMES, LAST_NAMES } = require('./_catalog');
const { API, accessToken, resetToken } = require('./_auth');

const MAX_ORDERS = 20;
const MAX_LINES = 6;
const MAX_QTY = 5;

const ORDER_CREATE = `mutation CreateTrainingOrder($data: CreateOrderInput!) {
  order_create(data: $data) {
    request_id
    complexity
    order { id legacy_id order_number fulfillment_status }
  }
}`;

const pick = (arr) => arr[Math.floor(Math.random() * arr.length)];

// Order numbers run TEST-TRAINING-001, -002, ... The next number comes from the
// highest one already in ShipHero, so it survives redeploys and cold starts.
const PREFIX = 'TEST-TRAINING-';
let lastIssued = 0; // guards against reusing a number before ShipHero lists it

const LATEST_ORDERS = `query LatestTraining($acct: String, $from: ISODateTime, $to: ISODateTime) {
  orders(customer_account_id: $acct, shop_name: "Picker Training", order_date_from: $from, order_date_to: $to) {
    data(first: 25, sort: "-order_date") { edges { node { order_number } } }
  }
}`;

async function highestOrderNumber(token) {
  const to = new Date();
  const from = new Date(to.getTime() - 365 * 24 * 3600 * 1000);
  const r = await fetch(`${API}/graphql`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    body: JSON.stringify({
      query: LATEST_ORDERS,
      variables: { acct: SHIPBOTS_ACCOUNT_ID, from: from.toISOString(), to: to.toISOString() },
    }),
  });
  const body = await r.json().catch(() => ({}));
  const edges = (body.data && body.data.orders && body.data.orders.data && body.data.orders.data.edges) || [];
  if (!r.ok || (body.errors && body.errors.length)) throw new Error('Could not read the last training order number from ShipHero.');
  let max = 0;
  for (const e of edges) {
    const m = /^TEST-TRAINING-(\d+)$/.exec((e.node && e.node.order_number) || '');
    if (m) max = Math.max(max, Number(m[1]));
  }
  return max;
}

const formatNumber = (n) => PREFIX + String(n).padStart(3, '0');

// Merge duplicate SKUs and reject anything outside the training catalog.
function cleanLines(lines) {
  if (!Array.isArray(lines) || lines.length === 0) throw new Error('Each order needs at least one item.');
  const merged = new Map();
  for (const l of lines) {
    const sku = String(l && l.sku || '').trim().toUpperCase();
    const qty = Number.parseInt(l && l.qty, 10);
    if (!PRODUCTS[sku]) throw new Error(`Unknown SKU: ${sku || '(blank)'}`);
    if (!Number.isInteger(qty) || qty < 1) throw new Error(`Bad quantity for ${sku}.`);
    merged.set(sku, Math.min(MAX_QTY, (merged.get(sku) || 0) + qty));
  }
  if (merged.size > MAX_LINES) throw new Error(`Max ${MAX_LINES} different items per order.`);
  return [...merged].map(([sku, qty]) => ({ sku, qty }));
}

function buildOrder(lines, number) {
  const first = pick(FIRST_NAMES);
  const last = pick(LAST_NAMES);
  const total = lines.reduce((s, l) => s + Number(PRODUCTS[l.sku].price) * l.qty, 0).toFixed(2);
  const address = { ...SHIP_TO, first_name: first, last_name: last };
  return {
    customer_account_id: SHIPBOTS_ACCOUNT_ID,
    order_number: number,
    partner_order_id: number,
    shop_name: 'Picker Training',
    fulfillment_status: 'pending',
    order_date: new Date().toISOString(),
    email: 'picker-training@example.com',
    tags: ['picker-training'],
    subtotal: total,
    total_price: total,
    total_tax: '0.00',
    total_discounts: '0.00',
    shipping_lines: { title: 'Standard', price: '0.00' },
    shipping_address: address,
    billing_address: address,
    skip_address_validation: true,
    ignore_address_validation_errors: true,
    line_items: lines.map((l, i) => ({
      sku: l.sku,
      partner_line_item_id: `${number}-${i + 1}`,
      quantity: l.qty,
      price: PRODUCTS[l.sku].price,
      product_name: PRODUCTS[l.sku].name,
    })),
  };
}

async function createOrder(token, data) {
  const r = await fetch(`${API}/graphql`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    body: JSON.stringify({ query: ORDER_CREATE, variables: { data } }),
  });
  if (r.status === 401) resetToken(); // token revoked: log in fresh on the next request
  const body = await r.json().catch(() => ({}));
  if (body.errors && body.errors.length) {
    throw new Error(body.errors.map((e) => e.message).join('; '));
  }
  const out = body.data && body.data.order_create;
  if (!r.ok || !out || !out.order) throw new Error(`ShipHero returned ${r.status}.`);
  return out.order;
}

module.exports = async function handler(req, res) {
  if (req.method !== 'POST') {
    res.setHeader('Allow', 'POST');
    return res.status(405).json({ error: 'POST only' });
  }
  const body = typeof req.body === 'string' ? JSON.parse(req.body || '{}') : (req.body || {});

  const pin = process.env.TRAINING_PIN;
  if (pin && String(body.pin || '') !== pin) return res.status(401).json({ error: 'Wrong PIN.' });

  let orders;
  try {
    if (!Array.isArray(body.orders) || body.orders.length === 0) throw new Error('No orders sent.');
    if (body.orders.length > MAX_ORDERS) throw new Error(`Max ${MAX_ORDERS} orders per click.`);
    orders = body.orders.map((o) => cleanLines(o && o.lines));
  } catch (e) {
    return res.status(400).json({ error: e.message });
  }

  let token;
  try {
    token = await accessToken();
  } catch (e) {
    return res.status(500).json({ error: e.message });
  }

  // Sequential on purpose: keeps us well under ShipHero's credit throttle.
  let next;
  try {
    next = Math.max(await highestOrderNumber(token), lastIssued) + 1;
  } catch (e) {
    return res.status(502).json({ error: e.message });
  }

  const results = [];
  for (const lines of orders) {
    lastIssued = next;
    const data = buildOrder(lines, formatNumber(next++));
    try {
      const order = await createOrder(token, data);
      results.push({
        ok: true,
        order_number: order.order_number,
        legacy_id: order.legacy_id,
        customer: `${data.shipping_address.first_name} ${data.shipping_address.last_name}`,
        lines,
      });
    } catch (e) {
      results.push({ ok: false, order_number: data.order_number, error: e.message, lines });
    }
  }
  return res.status(200).json({ results });
};
