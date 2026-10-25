import assert from 'node:assert/strict';
import test from 'node:test';
import { createHandler } from '../src/handler.js';

const identity = {
  sub: 'uid-123',
  email: 'user@example.test',
  email_verified: true,
};
const activeMembership = { active: true, role: 'manager', subjectId: undefined };
const activeStation = { active: true, name: 'محطة اختبار' };

function makeHarness({ identityResult = identity, membership = activeMembership, station = activeStation } = {}) {
  const calls = [];
  const handler = createHandler({
    verifyFirebaseIdToken: async (token) => {
      calls.push(['verify', token]);
      if (identityResult instanceof Error) throw identityResult;
      return identityResult;
    },
    firestore: {
      getMembership: async (uid, stationId) => {
        calls.push(['membership', uid, stationId]);
        return membership;
      },
      getStation: async (stationId) => {
        calls.push(['station', stationId]);
        return station;
      },
    },
  });
  return { handler, calls };
}

function request(path = '/api/v1/me', { method = 'GET', token = 'valid-token', stationId = 'station-1', origin } = {}) {
  const headers = new Headers();
  if (token) headers.set('authorization', `Bearer ${token}`);
  if (stationId) headers.set('x-station-id', stationId);
  if (origin) headers.set('origin', origin);
  return new Request(`https://api.example.test${path}`, { method, headers });
}

test('health endpoint is public and does not query Firebase', async () => {
  const { handler, calls } = makeHarness();
  const response = await handler(request('/health'));
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    ok: true,
    service: 'saqia-finance-api',
    mode: 'identity-bootstrap',
  });
  assert.deepEqual(calls, []);
});

test('requires a bearer token and exact station membership; there is no station fallback', async () => {
  const { handler, calls } = makeHarness();
  const missingToken = await handler(request('/api/v1/me', { token: null }));
  assert.equal(missingToken.status, 401);
  assert.deepEqual(calls, []);

  const missingStation = await handler(request('/api/v1/me', { stationId: null }));
  assert.equal(missingStation.status, 400);
  assert.deepEqual(calls.map((call) => call[0]), ['verify']);

  const malformedStation = await handler(request('/api/v1/me', { stationId: '../1' }));
  assert.equal(malformedStation.status, 400);
  assert.equal(calls.filter((call) => call[0] === 'membership').length, 0);
});

test('rejects invalid token, unverified email, missing membership and inactive membership', async () => {
  const invalid = makeHarness({ identityResult: new Error('bad token') });
  assert.equal((await invalid.handler(request())).status, 401);
  assert.equal(invalid.calls.filter((call) => call[0] === 'membership').length, 0);

  const unverified = makeHarness({ identityResult: { ...identity, email_verified: false } });
  assert.equal((await unverified.handler(request())).status, 401);
  assert.equal(unverified.calls.filter((call) => call[0] === 'membership').length, 0);

  const absent = makeHarness({ membership: null });
  assert.equal((await absent.handler(request())).status, 403);
  assert.equal(absent.calls.filter((call) => call[0] === 'station').length, 0);

  const inactive = makeHarness({ membership: { ...activeMembership, active: false } });
  assert.equal((await inactive.handler(request())).status, 403);
  assert.equal(inactive.calls.filter((call) => call[0] === 'station').length, 0);
});

test('rejects inactive stations, invalid roles and missing subject scope', async () => {
  assert.equal((await makeHarness({ station: { active: false } }).handler(request())).status, 403);
  assert.equal((await makeHarness({ membership: { active: true, role: 'rootAdmin' } }).handler(request())).status, 403);
  assert.equal((await makeHarness({ membership: { active: true, role: 'beneficiary' } }).handler(request())).status, 403);
});

test('returns only identity fields resolved from the verified token and Firestore membership', async () => {
  const { handler, calls } = makeHarness({
    membership: { active: true, role: 'beneficiary', subjectId: 'beneficiary-42' },
  });
  const response = await handler(request());
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), {
    uid: 'uid-123',
    email: 'user@example.test',
    stationId: 'station-1',
    role: 'beneficiary',
    subjectId: 'beneficiary-42',
  });
  assert.deepEqual(calls.filter((call) => call[0] !== 'verify'), [
    ['membership', 'uid-123', 'station-1'],
    ['station', 'station-1'],
  ]);
});

test('financial routes are fail-closed and do not call Firestore', async () => {
  const { handler, calls } = makeHarness();
  const response = await handler(request('/api/v1/finance/payments', { method: 'POST' }));
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), { error: 'financial_api_not_enabled' });
  assert.deepEqual(calls, []);
});

test('CORS only reflects an explicitly configured origin', async () => {
  const { handler } = makeHarness();
  const denied = await handler(request('/health', { origin: 'https://evil.example' }), {
    ALLOWED_ORIGINS: 'https://app.example',
  });
  assert.equal(denied.status, 403);

  const allowed = await handler(request('/health', { origin: 'https://app.example' }), {
    ALLOWED_ORIGINS: 'https://app.example, https://admin.example',
  });
  assert.equal(allowed.status, 200);
  assert.equal(allowed.headers.get('access-control-allow-origin'), 'https://app.example');
});
