// GET /api/recent: the latest training orders in ShipHero, newest first.
// Lets the page show real state on load and doubles as the "connected" check.
const { SHIPBOTS_ACCOUNT_ID } = require('./_catalog');
const { API, accessToken, resetToken } = require('./_auth');

const QUERY = `query RecentTraining($acct: String, $from: ISODateTime, $to: ISODateTime) {
  orders(customer_account_id: $acct, shop_name: "Picker Training", order_date_from: $from, order_date_to: $to) {
    data(first: 12, sort: "-order_date") {
      edges { node {
        order_number legacy_id fulfillment_status order_date
        line_items(first: 10) { edges { node { sku quantity } } }
      } }
    }
  }
}`;

module.exports = async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  try {
    const token = await accessToken();
    const to = new Date();
    const from = new Date(to.getTime() - 365 * 24 * 3600 * 1000);
    const r = await fetch(`${API}/graphql`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
      body: JSON.stringify({ query: QUERY, variables: { acct: SHIPBOTS_ACCOUNT_ID, from: from.toISOString(), to: to.toISOString() } }),
    });
    if (r.status === 401) resetToken();
    const body = await r.json().catch(() => ({}));
    if (!r.ok || (body.errors && body.errors.length)) throw new Error('ShipHero did not return orders.');
    const edges = (((body.data || {}).orders || {}).data || {}).edges || [];
    const orders = edges.map(({ node }) => ({
      number: node.order_number,
      id: node.legacy_id,
      status: node.fulfillment_status,
      date: node.order_date,
      lines: (node.line_items.edges || []).map((e) => ({ sku: e.node.sku, qty: e.node.quantity })),
    }));
    res.status(200).json({ ok: true, orders });
  } catch (e) {
    res.status(503).json({ ok: false, error: e.message, orders: [] });
  }
};
