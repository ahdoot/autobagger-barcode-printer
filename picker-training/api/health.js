// GET /api/health: confirms the app can still log in to ShipHero.
// Returns 200 {ok:true} or 503 {ok:false, error}. Never returns secrets.
const { accessToken, resetToken, tokenSource } = require('./_auth');

module.exports = async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  resetToken(); // always prove a fresh login works
  try {
    await accessToken();
    const via = tokenSource();
    res.status(200).json({
      ok: true,
      via,
      warning: via === 'password_login' ? 'Refresh token was rejected; running on the password fallback.' : null,
      fallbackConfigured: Boolean(process.env.SHIPHERO_USERNAME && process.env.SHIPHERO_PASSWORD),
    });
  } catch (e) {
    res.status(503).json({ ok: false, error: e.message });
  }
};
