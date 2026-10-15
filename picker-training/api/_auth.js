// ShipHero Public API auth with a self-healing fallback.
//
// 1. SHIPHERO_REFRESH_TOKEN  -> POST /auth/refresh (normal path; access tokens last 28 days)
// 2. SHIPHERO_USERNAME + SHIPHERO_PASSWORD -> POST /auth/token
//    Used only if the refresh token is missing or rejected, so an expired or
//    revoked refresh token never takes the app down.

const API = 'https://public-api.shiphero.com';

let cached = null; // { value, expiresAt, via }

async function post(path, payload) {
  const r = await fetch(`${API}${path}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  });
  const body = await r.json().catch(() => ({}));
  return { ok: r.ok && Boolean(body.access_token), status: r.status, body };
}

function remember(body, via) {
  cached = { value: body.access_token, expiresAt: Date.now() + (body.expires_in || 3600) * 1000, via };
  return cached.value;
}

async function accessToken() {
  if (cached && cached.expiresAt > Date.now() + 60_000) return cached.value;
  const { SHIPHERO_REFRESH_TOKEN: refresh, SHIPHERO_USERNAME: user, SHIPHERO_PASSWORD: pass } = process.env;
  const problems = [];

  if (refresh) {
    const r = await post('/auth/refresh', { refresh_token: refresh });
    if (r.ok) return remember(r.body, 'refresh_token');
    problems.push(`refresh token rejected (${r.status})`);
  } else {
    problems.push('SHIPHERO_REFRESH_TOKEN not set');
  }

  if (user && pass) {
    const r = await post('/auth/token', { username: user, password: pass });
    if (r.ok) return remember(r.body, 'password_login');
    problems.push(`password login rejected (${r.status})`);
  } else {
    problems.push('no SHIPHERO_USERNAME/SHIPHERO_PASSWORD fallback');
  }

  throw new Error(`ShipHero auth failed: ${problems.join('; ')}.`);
}

function resetToken() {
  cached = null;
}

function tokenSource() {
  return cached ? cached.via : null;
}

module.exports = { API, accessToken, resetToken, tokenSource };
