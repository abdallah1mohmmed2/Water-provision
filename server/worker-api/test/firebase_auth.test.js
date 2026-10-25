import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { importPKCS8, SignJWT } from 'jose';
import { createFirebaseTokenVerifier } from '../src/firebase_auth.js';

const projectId = 'saqia-test-project';
const now = () => Date.now();

function makeTestCertificate() {
  const directory = mkdtempSync(join(tmpdir(), 'saqia-firebase-test-'));
  const keyPath = join(directory, 'private.pem');
  const certificatePath = join(directory, 'certificate.pem');
  try {
    execFileSync('openssl', [
      'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
      '-keyout', keyPath, '-out', certificatePath,
      '-subj', '/CN=saqia-test-only', '-days', '2',
    ], { stdio: 'ignore' });
    return {
      directory,
      privateKeyPem: readFileSync(keyPath, 'utf8'),
      certificatePem: readFileSync(certificatePath, 'utf8'),
    };
  } catch (error) {
    rmSync(directory, { recursive: true, force: true });
    if (error.code === 'ENOENT') return null;
    throw error;
  }
}

const certificate = makeTestCertificate();

test('verifies Firebase token signature, issuer, audience and verified email', {
  skip: certificate ? false : 'OpenSSL is required only to generate an ephemeral test certificate',
}, async (t) => {
  t.after(() => rmSync(certificate.directory, { recursive: true, force: true }));
  const privateKey = await importPKCS8(certificate.privateKeyPem, 'RS256');
  let certificateFetches = 0;
  const verify = createFirebaseTokenVerifier({
    projectId,
    now,
    fetcher: async (url) => {
      assert.equal(url, 'https://www.googleapis.com/robot/v1/metadata/x509/securetoken@system.gserviceaccount.com');
      certificateFetches += 1;
      return new Response(JSON.stringify({ 'test-kid': certificate.certificatePem }), {
        status: 200,
        headers: { 'cache-control': 'public, max-age=300' },
      });
    },
  });

  async function token({ claims = {}, audience = projectId, issuer = `https://securetoken.google.com/${projectId}`, expiresAt, issuedAt, kid = 'test-kid' } = {}) {
    const current = Math.floor(now() / 1000);
    const issued = issuedAt ?? current;
    return new SignJWT({
      auth_time: current - 10,
      email: 'user@example.test',
      email_verified: true,
      ...claims,
    })
      .setProtectedHeader({ alg: 'RS256', kid, typ: 'JWT' })
      .setIssuer(issuer)
      .setAudience(audience)
      .setSubject('uid-test-123')
      .setIssuedAt(issued)
      .setExpirationTime(expiresAt ?? issued + 1800)
      .sign(privateKey);
  }

  const valid = await verify(await token());
  assert.equal(valid.sub, 'uid-test-123');
  assert.equal(valid.email_verified, true);
  assert.equal(certificateFetches, 1);

  await assert.rejects(verify(await token({ claims: { email_verified: false } })), /firebase_email_not_verified/);
  await assert.rejects(verify(await token({ audience: 'another-project' })), /audience|claim/i);
  await assert.rejects(verify(await token({ issuer: 'https://securetoken.google.com/another-project' })), /issuer|claim/i);
  await assert.rejects(verify(await token({ expiresAt: Math.floor(now() / 1000) - 120 })), /exp|expired|age/i);
  await assert.rejects(
    verify(await token({ claims: { auth_time: Math.floor(now() / 1000) + 120 } })),
    /time_claim_invalid/,
  );
  await assert.rejects(verify(await token({ claims: { auth_time: 'recent' } })), /time_claim_invalid/);
  assert.equal(certificateFetches, 1, 'certificate cache should be used for subsequent verifications');
});

test('accepts a valid token after a certificate rotation refresh', {
  skip: certificate ? false : 'OpenSSL is required only to generate an ephemeral test certificate',
}, async (t) => {
  t.after(() => rmSync(certificate.directory, { recursive: true, force: true }));
  const privateKey = await importPKCS8(certificate.privateKeyPem, 'RS256');
  let clock = Date.now() - 120_000;
  let fetches = 0;
  const verify = createFirebaseTokenVerifier({
    projectId,
    now: () => clock,
    fetcher: async () => {
      fetches += 1;
      const kid = fetches === 1 ? 'old-kid' : 'rotated-kid';
      return new Response(JSON.stringify({ [kid]: certificate.certificatePem }), {
        status: 200,
        headers: { 'cache-control': 'public, max-age=3600' },
      });
    },
  });
  async function token(kid) {
    const issued = Math.floor(clock / 1000);
    return new SignJWT({ auth_time: issued - 5, email_verified: true })
      .setProtectedHeader({ alg: 'RS256', kid, typ: 'JWT' })
      .setIssuer(`https://securetoken.google.com/${projectId}`)
      .setAudience(projectId)
      .setSubject('uid-test-123')
      .setIssuedAt(issued)
      .setExpirationTime(issued + 1800)
      .sign(privateKey);
  }
  assert.equal((await verify(await token('old-kid'))).sub, 'uid-test-123');
  clock += 61_000;
  assert.equal((await verify(await token('rotated-kid'))).sub, 'uid-test-123');
  assert.equal(fetches, 2);
});

test('refreshes once for an unknown key, then rate limits repeated refreshes', {
  skip: certificate ? false : 'OpenSSL is required only to generate an ephemeral test certificate',
}, async (t) => {
  t.after(() => rmSync(certificate.directory, { recursive: true, force: true }));
  const privateKey = await importPKCS8(certificate.privateKeyPem, 'RS256');
  let clock = Date.now() - 120_000;
  let fetches = 0;
  const verify = createFirebaseTokenVerifier({
    projectId,
    now: () => clock,
    fetcher: async () => {
      fetches += 1;
      return new Response(JSON.stringify({ 'test-kid': certificate.certificatePem }), {
        status: 200,
        headers: { 'cache-control': 'public, max-age=3600' },
      });
    },
  });
  async function token(kid) {
    const issued = Math.floor(clock / 1000);
    return new SignJWT({ auth_time: issued - 5, email_verified: true })
      .setProtectedHeader({ alg: 'RS256', kid, typ: 'JWT' })
      .setIssuer(`https://securetoken.google.com/${projectId}`)
      .setAudience(projectId)
      .setSubject('uid-test-123')
      .setIssuedAt(issued)
      .setExpirationTime(issued + 1800)
      .sign(privateKey);
  }
  assert.equal((await verify(await token('test-kid'))).sub, 'uid-test-123');
  clock += 61_000;
  await assert.rejects(verify(await token('unknown-one')), /key_unknown/);
  assert.equal(fetches, 2, 'an aged certificate set triggers one refresh');
  await assert.rejects(verify(await token('unknown-two')), /key_unknown/);
  assert.equal(fetches, 2, 'repeated unknown keys within the cooldown do not trigger fetches');
  clock += 61_000;
  await assert.rejects(verify(await token('unknown-three')), /key_unknown/);
  assert.equal(fetches, 3, 'a later unknown key may refresh after the cooldown');
});

test('rejects non-RS256 and malformed tokens before fetching certificates', async () => {
  let fetches = 0;
  const verify = createFirebaseTokenVerifier({
    projectId,
    fetcher: async () => {
      fetches += 1;
      return new Response('{}');
    },
  });
  const encoded = Buffer.from(JSON.stringify({ alg: 'HS256', kid: 'key' })).toString('base64url');
  await assert.rejects(verify(`${encoded}.e30.signature`), /header_invalid/);
  await assert.rejects(verify('not.a.valid.jwt'), /invalid/);
  assert.equal(fetches, 0);
});
