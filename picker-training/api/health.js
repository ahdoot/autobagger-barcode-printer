// GET /api/health: confirms the app can still log in to ShipHero.
// Checks the main login (refresh token, falling back to password) and, separately,
// that the backup username/password works on its own. Never returns secrets.
const { API, accessToken, resetToken, tokenSource } = require('./_auth');

async function backupLoginWorks() {
  const { SHIPHERO_USERNAME: username, SHIPHERO_PASSWORD: password } = process.env;
  if (!username || !password) return null;
  const r = await fetch(`${API}/auth/token`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username, password }),
  });
  const body = await r.json().catch(() => ({}));
  return r.ok && Boolean(body.access_token);
}

module.exports = async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  resetToken(); // always prove a fresh login works
  let backupOk = null;
  try { backupOk = await backupLoginWorks(); } catch (e) { backupOk = false; }
  try {
    await accessToken();
    const via = tokenSource();
    const warnings = [];
    if (via === 'password_login') warnings.push('Refresh token was rejected; running on the backup login.');
    if (backupOk === false) warnings.push('Backup username/password was rejected by ShipHero.');
    res.status(200).json({
      ok: true,
      via,
      fallbackConfigured: backupOk !== null,
      backupLoginOk: backupOk,
      warning: warnings.join(' ') || null,
    });
  } catch (e) {
    res.status(503).json({ ok: false, backupLoginOk: backupOk, error: e.message });
  }
};
