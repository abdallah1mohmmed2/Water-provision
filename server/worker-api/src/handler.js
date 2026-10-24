const VALID_ROLES = new Set([
  'manager',
  'accountant',
  'operations',
  'beneficiary',
  'partner',
  'worker',
]);
const SUBJECT_ROLES = new Set(['beneficiary', 'partner', 'worker']);
const STATION_ID_PATTERN = /^[A-Za-z0-9_-]{1,128}$/;

function jsonResponse(body, status = 200, headers = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8', ...headers },
  });
}

function allowedOrigins(env) {
  return new Set(
    String(env.ALLOWED_ORIGINS ?? '')
      .split(',')
      .map((value) => value.trim())
      .filter(Boolean),
  );
}

function applyCors(request, env, response) {
  const origin = request.headers.get('origin');
  if (!origin) return response;
  const origins = allowedOrigins(env);
  if (!origins.has(origin)) {
    return jsonResponse({ error: 'origin_not_allowed' }, 403, { vary: 'Origin' });
  }
  const headers = new Headers(response.headers);
  headers.set('access-control-allow-origin', origin);
  headers.set('access-control-allow-methods', 'GET, OPTIONS');
  headers.set('access-control-allow-headers', 'Authorization, X-Station-Id, Content-Type');
  headers.set('access-control-max-age', '600');
  headers.append('vary', 'Origin');
  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers,
  });
}

function bearerToken(request) {
  const value = request.headers.get('authorization');
  if (!value) return null;
  const match = /^Bearer ([^\s]+)$/i.exec(value);
  return match?.[1] ?? null;
}

export function createHandler({ verifyFirebaseIdToken, firestore }) {
  return async function handle(request, env = {}) {
    const url = new URL(request.url);
    let response;

    if (request.method === 'OPTIONS') {
      response = new Response(null, { status: 204 });
      return applyCors(request, env, response);
    }

    if (url.pathname === '/health' && request.method === 'GET') {
      response = jsonResponse({ ok: true, service: 'saqia-finance-api', mode: 'identity-bootstrap' });
      return applyCors(request, env, response);
    }

    if (url.pathname.startsWith('/api/v1/finance/')) {
      response = jsonResponse({ error: 'financial_api_not_enabled' }, 503);
      return applyCors(request, env, response);
    }

    if (url.pathname !== '/api/v1/me') {
      response = jsonResponse({ error: 'not_found' }, 404);
      return applyCors(request, env, response);
    }
    if (request.method !== 'GET') {
      response = jsonResponse({ error: 'method_not_allowed' }, 405, { allow: 'GET, OPTIONS' });
      return applyCors(request, env, response);
    }

    const token = bearerToken(request);
    if (!token) {
      response = jsonResponse({ error: 'unauthorized' }, 401);
      return applyCors(request, env, response);
    }

    let identity;
    try {
      identity = await verifyFirebaseIdToken(token);
    } catch {
      response = jsonResponse({ error: 'unauthorized' }, 401);
      return applyCors(request, env, response);
    }

    if (identity.email_verified !== true || typeof identity.sub !== 'string') {
      response = jsonResponse({ error: 'unauthorized' }, 401);
      return applyCors(request, env, response);
    }

    const stationId = request.headers.get('x-station-id');
    if (!stationId || !STATION_ID_PATTERN.test(stationId)) {
      response = jsonResponse({ error: 'station_id_required' }, 400);
      return applyCors(request, env, response);
    }

    try {
      const membership = await firestore.getMembership(identity.sub, stationId);
      if (!membership || membership.active !== true || !VALID_ROLES.has(membership.role)) {
        response = jsonResponse({ error: 'membership_not_active' }, 403);
        return applyCors(request, env, response);
      }
      if (SUBJECT_ROLES.has(membership.role) && !membership.subjectId) {
        response = jsonResponse({ error: 'membership_scope_invalid' }, 403);
        return applyCors(request, env, response);
      }

      const station = await firestore.getStation(stationId);
      if (!station || station.active !== true) {
        response = jsonResponse({ error: 'station_not_active' }, 403);
        return applyCors(request, env, response);
      }

      response = jsonResponse({
        uid: identity.sub,
        email: identity.email ?? null,
        stationId,
        role: membership.role,
        subjectId: membership.subjectId ?? null,
      });
      return applyCors(request, env, response);
    } catch {
      response = jsonResponse({ error: 'identity_directory_unavailable' }, 503);
      return applyCors(request, env, response);
    }
  };
}
