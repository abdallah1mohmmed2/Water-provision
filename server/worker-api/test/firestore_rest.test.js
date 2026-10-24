import assert from 'node:assert/strict';
import { generateKeyPair, exportPKCS8, jwtVerify } from 'jose';
import test from 'node:test';
import { createFirestoreDirectory } from '../src/firestore_rest.js';

const projectId = 'saqia-test-project';

async function createAccount(project = projectId, email = 'saqia-worker@example.iam.gserviceaccount.com') {
  const { privateKey, publicKey } = await generateKeyPair('RS256', { extractable: true });
  return {
    publicKey,
    json: JSON.stringify({
      type: 'service_account',
      project_id: project,
      client_email: email,
      private_key: await exportPKCS8(privateKey),
    }),
  };
}

test('uses a short-lived datastore OAuth assertion and reads only the UID membership and station documents', async () => {
  const account = await createAccount();
  const calls = [];
  const fetcher = async (url, init = {}) => {
    calls.push({ url: String(url), init });
    if (String(url) === 'https://oauth2.googleapis.com/token') {
      const form = new URLSearchParams(init.body);
      assert.equal(form.get('grant_type'), 'urn:ietf:params:oauth:grant-type:jwt-bearer');
      const { payload } = await jwtVerify(form.get('assertion'), account.publicKey, {
        issuer: 'saqia-worker@example.iam.gserviceaccount.com',
        audience: 'https://oauth2.googleapis.com/token',
      });
      assert.equal(payload.scope, 'https://www.googleapis.com/auth/datastore');
      assert.ok(payload.exp - payload.iat <= 3600);
      return new Response(JSON.stringify({ access_token: 'test-access-token', expires_in: 3600 }), {
        status: 200,
        headers: { 'content-type': 'application/json' },
      });
    }
    if (String(url).endsWith('/users/uid-123/memberships/station-1')) {
      return new Response(JSON.stringify({
        fields: {
          active: { booleanValue: true },
          role: { stringValue: 'manager' },
        },
      }), { status: 200, headers: { 'content-type': 'application/json' } });
    }
    if (String(url).endsWith('/stations/station-1')) {
      return new Response(JSON.stringify({
        fields: {
          active: { booleanValue: true },
          name: { stringValue: 'محطة اختبار' },
        },
      }), { status: 200, headers: { 'content-type': 'application/json' } });
    }
    throw new Error(`Unexpected URL: ${url}`);
  };

  const directory = createFirestoreDirectory({ projectId, serviceAccountJson: account.json, fetcher });
  assert.deepEqual(await directory.getMembership('uid-123', 'station-1'), {
    active: true,
    role: 'manager',
    subjectId: undefined,
  });
  assert.deepEqual(await directory.getStation('station-1'), {
    active: true,
    name: 'محطة اختبار',
  });

  const firestoreCalls = calls.filter((call) => call.url.startsWith('https://firestore.googleapis.com/'));
  assert.equal(firestoreCalls.length, 2);
  assert.ok(firestoreCalls[0].url.endsWith('/users/uid-123/memberships/station-1'));
  assert.ok(firestoreCalls[1].url.endsWith('/stations/station-1'));
  assert.ok(firestoreCalls.every((call) => call.init.headers.authorization === 'Bearer test-access-token'));
  assert.equal(calls.filter((call) => call.url === 'https://oauth2.googleapis.com/token').length, 1);
});

test('rotating the service-account secret invalidates the cached OAuth access token', async () => {
  const account = await createAccount();
  let fetches = 0;
  const directory = createFirestoreDirectory({
    projectId,
    serviceAccountJson: account.json,
    fetcher: async (url) => {
      fetches += 1;
      if (String(url) === 'https://oauth2.googleapis.com/token') {
        return new Response(JSON.stringify({ access_token: 'old-token', expires_in: 3600 }), { status: 200 });
      }
      return new Response(JSON.stringify({ fields: { active: { booleanValue: true } } }), { status: 200 });
    },
  });
  await directory.getStation('station-1');
  assert.equal(fetches, 2);

  directory.setServiceAccountJson(JSON.stringify({
    type: 'service_account',
    project_id: 'another-project',
    client_email: 'rotated@example.iam.gserviceaccount.com',
    private_key: account.json,
  }));
  await assert.rejects(directory.getStation('station-1'), /service_account_invalid/);
  assert.equal(fetches, 2, 'stale credentials and OAuth token must not be used after rotation');
});

test('rejects mismatched project credentials before making any request', async () => {
  let calls = 0;
  const account = await createAccount('another-project', 'bad@example.iam.gserviceaccount.com');
  const directory = createFirestoreDirectory({
    projectId,
    serviceAccountJson: account.json,
    fetcher: async () => {
      calls += 1;
      return new Response('{}');
    },
  });
  await assert.rejects(directory.getStation('station-1'), /service_account_invalid/);
  assert.equal(calls, 0);
});

test('rejects unsafe Firestore document identifiers before loading credentials', async () => {
  const directory = createFirestoreDirectory({ projectId, serviceAccountJson: '{}' });
  await assert.rejects(directory.getStation('../station'), /document_id_invalid/);
});
