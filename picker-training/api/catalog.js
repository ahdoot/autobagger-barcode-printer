// GET /api/catalog: the training products, for the page to render.
const { PRODUCTS } = require('./_catalog');

module.exports = function handler(req, res) {
  res.setHeader('Cache-Control', 's-maxage=300');
  res.status(200).json({ products: PRODUCTS, pinRequired: Boolean(process.env.TRAINING_PIN) });
};
