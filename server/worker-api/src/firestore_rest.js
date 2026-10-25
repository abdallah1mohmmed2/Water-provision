import { importPKCS8, SignJWT } from 'jose';

const GOOGLE_TOKEN_URL = 'https://oauth2.googleapis.com/token';
const DATASTORE_SCOPE = 'https://www.googleapis.com/auth/datastore';

function encodePathSegment(value) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(value)) {
    throw new Error('firestore_document_id_invalid');
  }
  return encodeURIComponent(value);
}

function stringField(fields, name) {
  const value = fields?.[name]?.stringValue;
  return typeof value === 'string' ? value : undefined;
}

function booleanField(fields, name) {
  const value = fields?.[name]?.booleanValue;
  return typeof value === 'boolean' ? value : undefined;
}

export class FirestoreRestError extends Error {
  constructor(status) {
    super('firestore_rest_request_failed');
    this.name = 'FirestoreRestError';
    this.status = status;
  }
}

export function createFirestoreDirectory({
  projectId,
  serviceAccountJson,
  fetcher = fetch,
  now = () => Date.now(),
} = {}) {
  let activeServiceAccountJson = serviceAccountJson;
  let serviceAccount;
  let cachedToken;
  let tokenExpiresAt = 0;
  let pendingToken;
  let credentialGeneration = 0;

  function setServiceAccountJson(nextValue) {
    if (nextValue === activeServiceAccountJson) return;
    activeServiceAccountJson = nextValue;
    serviceAccount = undefined;
    cachedToken = undefined;
    tokenExpiresAt = 0;
    pendingToken = undefined;
    credentialGeneration += 1;
  }

  function getServiceAccount() {
    if (serviceAccount) return serviceAccount;
    if (typeof activeServiceAccountJson !== 'string' || activeServiceAccountJson.length > 20_000) {
      throw new Error('firestore_service_account_not_configured');
    }
    let parsed;
    try {
      parsed = JSON.parse(activeServiceAccountJson);
    } catch {
      throw new Error('firestore_service_account_invalid');
    }
    if (
      parsed?.type !== 'service_account' ||
      typeof projectId !== 'string' ||
      parsed?.project_id !== projectId ||
      typeof parsed?.client_email !== 'string' ||
      typeof parsed?.private_key !== 'string' ||
      !parsed.private_key.includes('PRIVATE KEY')
    ) {
      throw new Error('firestore_service_account_invalid');
    }
    serviceAccount = parsed;
    return serviceAccount;
  }

  async function getAccessToken() {
    const account = getServiceAccount();
    if (cachedToken && now() < tokenExpiresAt - 60_000) return cachedToken;
    if (pendingToken) return pendingToken;

    const generation = credentialGeneration;
    const pending = (async () => {
      const issuedAt = Math.floor(now() / 1000);
      const privateKey = await importPKCS8(account.private_key, 'RS256');
      const assertion = await new SignJWT({ scope: DATASTORE_SCOPE })
        .setProtectedHeader({ alg: 'RS256', typ: 'JWT' })
        .setIssuer(account.client_email)
        .setAudience(GOOGLE_TOKEN_URL)
        .setIssuedAt(issuedAt)
        .setExpirationTime(issuedAt + 3600)
        .sign(privateKey);

      const response = await fetcher(GOOGLE_TOKEN_URL, {
        method: 'POST',
        headers: { 'content-type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({
          grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
          assertion,
        }),
      });
      if (generation !== credentialGeneration) {
        throw new Error('firestore_service_account_rotated');
      }
      if (!response.ok) throw new Error('google_oauth_exchange_failed');
      const result = await response.json();
      if (
        typeof result?.access_token !== 'string' ||
        !Number.isFinite(result?.expires_in) ||
        result.expires_in <= 60
      ) {
        throw new Error('google_oauth_response_invalid');
      }
      cachedToken = result.access_token;
      tokenExpiresAt = now() + result.expires_in * 1000;
      return cachedToken;
    })();
    pendingToken = pending;

    try {
      return await pending;
    } finally {
      if (pendingToken === pending) pendingToken = undefined;
    }
  }

  async function getDocument(pathSegments) {
    const path = pathSegments.map(encodePathSegment).join('/');
    getServiceAccount();
    const url = `https://firestore.googleapis.com/v1/projects/${encodeURIComponent(projectId)}/databases/(default)/documents/${path}`;
    const accessToken = await getAccessToken();
    const response = await fetcher(url, {
      headers: {
        authorization: `Bearer ${accessToken}`,
        accept: 'application/json',
      },
    });
    if (response.status === 404) return null;
    if (!response.ok) throw new FirestoreRestError(response.status);
    return response.json();
  }

  return {
    setServiceAccountJson,
    async getMembership(uid, stationId) {
      const document = await getDocument(['users', uid, 'memberships', stationId]);
      if (!document) return null;
      const fields = document.fields ?? {};
      return {
        active: booleanField(fields, 'active'),
        role: stringField(fields, 'role'),
        subjectId: stringField(fields, 'subjectId'),
      };
    },

    async getStation(stationId) {
      const document = await getDocument(['stations', stationId]);
      if (!document) return null;
      const fields = document.fields ?? {};
      return {
        active: booleanField(fields, 'active'),
        name: stringField(fields, 'name'),
      };
    },
  };
}
