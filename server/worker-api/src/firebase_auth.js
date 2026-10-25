import { decodeProtectedHeader, importX509, jwtVerify } from 'jose';

const FIREBASE_CERTS_URL =
  'https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com';
const MAX_CERT_CACHE_SECONDS = 24 * 60 * 60;
const UNKNOWN_KID_REFRESH_COOLDOWN_MS = 60_000;

function cacheMaxAgeSeconds(value) {
  const match = /(?:^|,)\s*max-age=(\d+)/i.exec(value ?? '');
  if (!match) return 300;
  return Math.min(Number(match[1]), MAX_CERT_CACHE_SECONDS);
}

function parseCertificateMap(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) {
    throw new Error('firebase_certificate_response_invalid');
  }
  const entries = Object.entries(value).filter(
    ([kid, cert]) =>
      typeof kid === 'string' &&
      kid.length > 0 &&
      typeof cert === 'string' &&
      cert.includes('BEGIN CERTIFICATE'),
  );
  if (entries.length === 0) throw new Error('firebase_certificate_set_empty');
  return Object.fromEntries(entries);
}

export function createFirebaseTokenVerifier({
  projectId,
  fetcher = fetch,
  now = () => Date.now(),
} = {}) {
  let cachedCerts;
  let certsExpireAt = 0;
  let lastCertFetchAt = 0;
  let lastUnknownKidRefreshAt = 0;
  let pendingCertFetch;

  async function getCertificates() {
    if (cachedCerts && now() < certsExpireAt) return cachedCerts;
    if (pendingCertFetch) return pendingCertFetch;

    const pending = (async () => {
      const response = await fetcher(FIREBASE_CERTS_URL, {
        headers: { accept: 'application/json' },
      });
      if (!response.ok) throw new Error('firebase_certificate_fetch_failed');
      const certificateMap = parseCertificateMap(await response.json());
      const fetchedAt = now();
      const maxAge = cacheMaxAgeSeconds(response.headers.get('cache-control'));
      cachedCerts = certificateMap;
      certsExpireAt = fetchedAt + maxAge * 1000;
      lastCertFetchAt = fetchedAt;
      return certificateMap;
    })();
    pendingCertFetch = pending;

    try {
      return await pending;
    } finally {
      if (pendingCertFetch === pending) pendingCertFetch = undefined;
    }
  }

  async function refreshUnknownKid() {
    const currentTime = now();
    if (cachedCerts && currentTime - lastCertFetchAt < UNKNOWN_KID_REFRESH_COOLDOWN_MS) {
      return cachedCerts;
    }
    if (currentTime - lastUnknownKidRefreshAt < UNKNOWN_KID_REFRESH_COOLDOWN_MS) {
      return cachedCerts;
    }
    lastUnknownKidRefreshAt = currentTime;
    cachedCerts = undefined;
    certsExpireAt = 0;
    return getCertificates();
  }

  return async function verifyFirebaseIdToken(token) {
    if (typeof projectId !== 'string' || projectId.trim() === '') {
      throw new Error('firebase_project_id_not_configured');
    }
    if (typeof token !== 'string' || token.length < 20 || token.length > 16_384) {
      throw new Error('firebase_token_invalid');
    }

    let header;
    try {
      header = decodeProtectedHeader(token);
    } catch {
      throw new Error('firebase_token_invalid');
    }
    if (header.alg !== 'RS256' || typeof header.kid !== 'string' || header.kid.length > 256) {
      throw new Error('firebase_token_header_invalid');
    }

    let certificates = await getCertificates();
    if (!certificates[header.kid]) {
      certificates = await refreshUnknownKid();
    }
    const certificate = certificates?.[header.kid];
    if (!certificate) throw new Error('firebase_token_key_unknown');

    const publicKey = await importX509(certificate, 'RS256');
    const { payload } = await jwtVerify(token, publicKey, {
      algorithms: ['RS256'],
      issuer: `https://securetoken.google.com/${projectId}`,
      audience: projectId,
      requiredClaims: ['exp', 'iat', 'auth_time', 'sub'],
      maxTokenAge: 3600,
      clockTolerance: 60,
      currentDate: new Date(now()),
    });

    const currentSeconds = Math.floor(now() / 1000);
    if (
      typeof payload.iat !== 'number' ||
      !Number.isFinite(payload.iat) ||
      payload.iat > currentSeconds + 60 ||
      typeof payload.auth_time !== 'number' ||
      !Number.isFinite(payload.auth_time) ||
      payload.auth_time < 0 ||
      payload.auth_time > currentSeconds + 60 ||
      payload.auth_time > payload.iat + 60
    ) {
      throw new Error('firebase_token_time_claim_invalid');
    }
    if (typeof payload.sub !== 'string' || payload.sub.length === 0 || payload.sub.length > 128) {
      throw new Error('firebase_token_subject_invalid');
    }
    if (payload.email_verified !== true) throw new Error('firebase_email_not_verified');
    return payload;
  };
}
