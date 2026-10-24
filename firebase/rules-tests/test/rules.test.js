import { readFileSync } from 'node:fs';
import { before, after, test } from 'node:test';
import assert from 'node:assert/strict';
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from '@firebase/rules-unit-testing';
import {
  collection,
  deleteDoc,
  doc,
  getDoc,
  getDocs,
  query,
  where,
  serverTimestamp,
  setDoc,
  Timestamp,
  updateDoc,
  writeBatch,
} from 'firebase/firestore';

const projectId = 'demo-saqia-rules-tests';
const rootAdminUid = 'wvzNFQ3S8mbH7jwszcvErj2kUv82';
const rules = readFileSync(new URL('../../../firestore.rules', import.meta.url), 'utf8');
let testEnv;

const actors = {
  manager: 'user-manager',
  accountant: 'user-accountant',
  operations: 'user-operations',
  beneficiary: 'user-beneficiary',
  partner: 'user-partner',
  worker: 'user-worker',
  otherStationManager: 'user-other-station-manager',
  disabledManager: 'user-disabled-manager',
  applicant: 'user-applicant',
  secondApplicant: 'user-second-applicant',
};

function stationDoc(db, path) {
  return doc(db, `stations/station-a/${path}`);
}

function signedIn(uid, claims = {}) {
  return testEnv.authenticatedContext(uid, claims).firestore();
}

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId,
    firestore: {
      host: '127.0.0.1',
      port: 8080,
      rules,
    },
  });

  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    const memberships = [
      [actors.manager, 'station-a', { role: 'manager', active: true }],
      [actors.accountant, 'station-a', { role: 'accountant', active: true }],
      [actors.operations, 'station-a', { role: 'operations', active: true }],
      [actors.beneficiary, 'station-a', {
        role: 'beneficiary', active: true, subjectId: 'beneficiary-1',
      }],
      [actors.partner, 'station-a', {
        role: 'partner', active: true, subjectId: 'partner-1',
      }],
      [actors.worker, 'station-a', {
        role: 'worker', active: true, subjectId: 'worker-1',
      }],
      [actors.otherStationManager, 'station-b', { role: 'manager', active: true }],
      [actors.disabledManager, 'station-a', { role: 'manager', active: false }],
    ];

    await Promise.all(memberships.map(([uid, stationId, membership]) =>
      setDoc(doc(db, `users/${uid}/memberships/${stationId}`), membership)));

    await Promise.all([
      setDoc(doc(db, `users/${actors.manager}`), { displayName: 'مدير' }),
      setDoc(doc(db, `users/${actors.beneficiary}`), { displayName: 'مستفيد' }),
      setDoc(doc(db, 'stations/station-a'), { name: 'المحطة أ' }),
      setDoc(doc(db, 'stations/station-b'), { name: 'المحطة ب' }),
      setDoc(doc(db, 'stations/station-a/beneficiaries/beneficiary-1'), {
        name: 'مستفيد 1', balance: 1250,
      }),
      setDoc(doc(db, 'stations/station-a/beneficiaries/beneficiary-2'), {
        name: 'مستفيد 2', balance: 0,
      }),
      setDoc(doc(db, 'stations/station-a/partners/partner-1'), { name: 'شريك 1' }),
      setDoc(doc(db, 'stations/station-a/partners/partner-2'), { name: 'شريك 2' }),
      setDoc(doc(db, 'stations/station-a/workers/worker-1'), { name: 'عامل 1' }),
      setDoc(doc(db, 'stations/station-a/workers/worker-2'), { name: 'عامل 2' }),
      setDoc(doc(db, 'stations/station-a/operationalProfiles/beneficiary-1'), {
        displayName: 'مستفيد 1', contactPhone: 'غير مخزن للاختبار', active: true,
      }),
      setDoc(doc(db, 'stations/station-a/ledgerEntries/entry-1'), { amount: 500 }),
      setDoc(doc(db, 'stations/station-a/journalEntries/journal-1'), { amount: 500 }),
      setDoc(doc(db, 'stations/station-a/payments/payment-1'), { amount: 250 }),
      setDoc(doc(db, 'stations/station-a/irrigations/irrigation-1'), { minutes: 30 }),
      setDoc(doc(db, 'stations/station-a/announcements/news-1'), {
        title: 'إعلان', body: 'نص', createdAt: Timestamp.now(),
      }),
      setDoc(doc(db, 'stations/station-a/statements/beneficiary/accounts/beneficiary-1'), {
        balance: 1250,
      }),
      setDoc(doc(db, 'stations/station-a/statements/beneficiary/accounts/beneficiary-1/entries/entry-1'), {
        amount: 500,
      }),
      setDoc(doc(db, 'stations/station-a/statements/partner/accounts/partner-1/entries/entry-1'), {
        amount: 100,
      }),
      setDoc(doc(db, 'stations/station-a/statements/worker/accounts/worker-1/entries/entry-1'), {
        amount: 75,
      }),
      setDoc(doc(db, 'stations/station-a/bookingRequests/request-1'), {
        beneficiaryId: 'beneficiary-1',
        requestedDate: Timestamp.fromDate(new Date('2026-10-25T08:00:00Z')),
        status: 'new',
        createdAt: Timestamp.now(),
      }),
      setDoc(doc(db, 'stations/station-a/bookingRequests/request-2'), {
        beneficiaryId: 'beneficiary-2',
        requestedDate: Timestamp.fromDate(new Date('2026-10-26T08:00:00Z')),
        status: 'new',
        createdAt: Timestamp.now(),
      }),
      setDoc(doc(db, 'stations/station-b/beneficiaries/secret'), { name: 'سر' }),
      setDoc(doc(db, `accessRequests/${actors.applicant}`), {
        email: 'applicant@example.com',
        displayName: 'مستخدم منتظر',
        status: 'pending',
        createdAt: Timestamp.now(),
      }),
      setDoc(doc(db, `accessRequests/${actors.secondApplicant}`), {
        email: 'second@example.com',
        displayName: 'مستخدم ثان',
        status: 'pending',
        createdAt: Timestamp.now(),
      }),
    ]);
  });
});

after(async () => {
  await testEnv?.cleanup();
});

test('manager and accountant can read station finance but cannot write ledgers', async () => {
  const managerDb = signedIn(actors.manager);
  const accountantDb = signedIn(actors.accountant);
  const announcement = {
    title: 'تنبيه تشغيل',
    body: 'إعلان محدود للمحطة',
    createdAt: serverTimestamp(),
  };
  await assertSucceeds(setDoc(stationDoc(managerDb, 'announcements/manager-notice'), announcement));
  await assertFails(setDoc(stationDoc(accountantDb, 'announcements/accountant-notice'), announcement));

  for (const uid of [actors.manager, actors.accountant]) {
    const db = signedIn(uid);
    await assertSucceeds(getDoc(stationDoc(db, 'journalEntries/journal-1')));
    await assertSucceeds(getDoc(stationDoc(db, 'payments/payment-1')));
    await assertFails(setDoc(stationDoc(db, 'journalEntries/forged'), { amount: 1 }));
    await assertFails(updateDoc(stationDoc(db, 'ledgerEntries/entry-1'), { amount: 1 }));
  }
});

test('operations can read operational records but not financial records or write either', async () => {
  const db = signedIn(actors.operations);
  await assertSucceeds(getDoc(stationDoc(db, 'irrigations/irrigation-1')));
  await assertSucceeds(getDoc(stationDoc(db, 'operationalProfiles/beneficiary-1')));
  await assertFails(getDoc(stationDoc(db, 'beneficiaries/beneficiary-1')));
  await assertFails(getDoc(stationDoc(db, 'journalEntries/journal-1')));
  await assertFails(setDoc(stationDoc(db, 'irrigations/forged'), { minutes: 999 }));
  await assertFails(deleteDoc(stationDoc(db, 'payments/payment-1')));
});

test('beneficiary reads only own profile and statement, and may create/cancel own request', async () => {
  const db = signedIn(actors.beneficiary);
  await assertSucceeds(getDoc(stationDoc(db, 'beneficiaries/beneficiary-1')));
  await assertFails(getDoc(stationDoc(db, 'beneficiaries/beneficiary-2')));
  await assertSucceeds(getDoc(stationDoc(
    db,
    'statements/beneficiary/accounts/beneficiary-1/entries/entry-1',
  )));
  await assertFails(getDoc(stationDoc(db, 'journalEntries/journal-1')));
  await assertFails(getDocs(query(collection(db, 'stations/station-a/bookingRequests'))));
  await assertSucceeds(getDocs(query(
    collection(db, 'stations/station-a/bookingRequests'),
    where('beneficiaryId', '==', 'beneficiary-1'),
  )));

  await assertSucceeds(setDoc(stationDoc(db, 'bookingRequests/beneficiary-new'), {
    beneficiaryId: 'beneficiary-1',
    requestedDate: Timestamp.fromDate(new Date('2026-10-27T08:00:00Z')),
    status: 'new',
    createdAt: serverTimestamp(),
    notes: 'موعد صباحي',
  }));
  await assertFails(setDoc(stationDoc(db, 'bookingRequests/for-another'), {
    beneficiaryId: 'beneficiary-2',
    requestedDate: Timestamp.fromDate(new Date('2026-10-27T08:00:00Z')),
    status: 'new',
    createdAt: serverTimestamp(),
  }));
  await assertFails(updateDoc(stationDoc(db, 'beneficiaries/beneficiary-1'), {
    balance: 0,
  }));
  await assertSucceeds(updateDoc(stationDoc(db, 'bookingRequests/request-1'), {
    status: 'cancelled',
    cancelledAt: serverTimestamp(),
  }));
  await assertFails(deleteDoc(stationDoc(db, 'bookingRequests/request-2')));
});

test('partner reads only own profile and statement and cannot write financial data', async () => {
  const db = signedIn(actors.partner);
  await assertSucceeds(getDoc(stationDoc(db, 'partners/partner-1')));
  await assertFails(getDoc(stationDoc(db, 'partners/partner-2')));
  await assertSucceeds(getDoc(stationDoc(
    db,
    'statements/partner/accounts/partner-1/entries/entry-1',
  )));
  await assertFails(getDoc(stationDoc(db, 'journalEntries/journal-1')));
  await assertFails(setDoc(stationDoc(db, 'payments/forged'), { amount: 1 }));
});

test('worker reads only own profile and statement and cannot write financial data', async () => {
  const db = signedIn(actors.worker);
  await assertSucceeds(getDoc(stationDoc(db, 'workers/worker-1')));
  await assertFails(getDoc(stationDoc(db, 'workers/worker-2')));
  await assertSucceeds(getDoc(stationDoc(
    db,
    'statements/worker/accounts/worker-1/entries/entry-1',
  )));
  await assertFails(getDoc(stationDoc(db, 'payments/payment-1')));
  await assertFails(updateDoc(stationDoc(db, 'workers/worker-1'), { name: 'تغيير' }));
});

test('manager and operations can review a booking request using a constrained transition', async () => {
  const managerDb = signedIn(actors.manager);
  await assertSucceeds(updateDoc(stationDoc(managerDb, 'bookingRequests/request-2'), {
    status: 'scheduled',
    reviewedAt: serverTimestamp(),
    reviewedBy: actors.manager,
  }));
  await assertFails(updateDoc(stationDoc(managerDb, 'bookingRequests/request-2'), {
    status: 'scheduled',
    amount: 999,
  }));
});

test('station membership prevents cross-station access; inactive membership is denied', async () => {
  const otherStationDb = signedIn(actors.otherStationManager);
  const disabledDb = signedIn(actors.disabledManager);
  await assertSucceeds(getDoc(doc(otherStationDb, 'stations/station-b/beneficiaries/secret')));
  await assertFails(getDoc(doc(otherStationDb, 'stations/station-a/beneficiaries/beneficiary-1')));
  await assertFails(getDoc(stationDoc(disabledDb, 'beneficiaries/beneficiary-1')));
});

test('clients cannot self-assign role or station membership; user can edit only safe preferences', async () => {
  const db = signedIn(actors.beneficiary);
  await assertSucceeds(updateDoc(doc(db, `users/${actors.beneficiary}`), {
    displayName: 'اسم محدث',
    updatedAt: serverTimestamp(),
  }));
  await assertFails(updateDoc(doc(db, `users/${actors.beneficiary}`), {
    role: 'manager',
  }));
  await assertFails(setDoc(doc(
    db,
    `users/${actors.beneficiary}/memberships/station-a`,
  ), { role: 'manager', active: true }));
  await assertFails(setDoc(doc(db, 'stations/station-a/private/secret'), { value: 'x' }));
});

test('unauthenticated access and client deletes are denied', async () => {
  const db = testEnv.unauthenticatedContext().firestore();
  await assertFails(getDoc(stationDoc(db, 'announcements/news-1')));
  await assertFails(setDoc(stationDoc(db, 'announcements/public'), {
    title: 'عام', body: 'غير مسموح', createdAt: serverTimestamp(),
  }));
  await assertFails(deleteDoc(stationDoc(db, 'beneficiaries/beneficiary-1')));
  await assertFails(getDocs(query(collection(db, 'stations/station-a/ledgerEntries'))));
});

test('verified users can request access but cannot choose a role or station', async () => {
  const applicantDb = signedIn(actors.applicant, {
    email: 'applicant@example.com',
    email_verified: true,
  });
  const requestRef = doc(applicantDb, `accessRequests/${actors.applicant}`);
  await assertSucceeds(getDoc(requestRef));
  await assertFails(updateDoc(requestRef, { status: 'approved' }));
  await assertFails(setDoc(doc(
    applicantDb,
    `users/${actors.applicant}/memberships/station-a`,
  ), { role: 'manager', active: true }));

  const unverifiedDb = signedIn('user-unverified', {
    email: 'unverified@example.com',
    email_verified: false,
  });
  await assertFails(setDoc(doc(unverifiedDb, 'accessRequests/user-unverified'), {
    email: 'unverified@example.com',
    displayName: 'غير موثق',
    status: 'pending',
    createdAt: serverTimestamp(),
  }));

  await assertFails(setDoc(doc(applicantDb, 'accessRequests/spoofed'), {
    email: 'victim@example.com',
    displayName: 'بريد مزور',
    status: 'pending',
    createdAt: serverTimestamp(),
  }));
  await assertFails(setDoc(doc(applicantDb, 'accessRequests/role-injection'), {
    email: 'applicant@example.com',
    displayName: 'طلب غير صالح',
    status: 'pending',
    role: 'manager',
    stationId: 'station-a',
    createdAt: serverTimestamp(),
  }));
});

test('verified fixed superadmin can create stations and atomically approve valid memberships', async () => {
  const adminDb = signedIn(rootAdminUid, {
    email: 'owner@example.com',
    email_verified: true,
  });
  await assertSucceeds(setDoc(doc(adminDb, 'stations/station-new'), {
    name: 'محطة جديدة',
    active: true,
    createdAt: serverTimestamp(),
    createdBy: rootAdminUid,
  }));
  await assertFails(deleteDoc(doc(adminDb, 'stations/station-new')));
  await assertFails(getDoc(stationDoc(adminDb, 'payments/payment-1')));

  const applicantProfile = doc(adminDb, `users/${actors.applicant}`);
  const applicantMembership = doc(
    adminDb,
    `users/${actors.applicant}/memberships/station-a`,
  );
  const applicantRequest = doc(adminDb, `accessRequests/${actors.applicant}`);
  const batch = writeBatch(adminDb);
  batch.set(applicantProfile, {
    email: 'applicant@example.com',
    displayName: 'مستخدم منتظر',
    createdAt: serverTimestamp(),
  });
  batch.set(applicantMembership, {
    role: 'beneficiary',
    active: true,
    subjectId: 'beneficiary-1',
    assignedAt: serverTimestamp(),
    assignedBy: rootAdminUid,
  });
  batch.update(applicantRequest, {
    status: 'approved',
    reviewedAt: serverTimestamp(),
    reviewedBy: rootAdminUid,
  });
  await assertSucceeds(batch.commit());

  const applicantDb = signedIn(actors.applicant, {
    email: 'applicant@example.com',
    email_verified: true,
  });
  await assertSucceeds(getDoc(doc(
    applicantDb,
    `users/${actors.applicant}/memberships/station-a`,
  )));
  await assertSucceeds(getDoc(doc(applicantDb, 'stations/station-a/beneficiaries/beneficiary-1')));
  await assertFails(getDoc(doc(applicantDb, 'stations/station-a/payments/payment-1')));

  const missingSubjectBatch = writeBatch(adminDb);
  missingSubjectBatch.set(doc(adminDb, `users/${actors.secondApplicant}`), {
    email: 'second@example.com',
    displayName: 'مستخدم ثان',
    createdAt: serverTimestamp(),
  });
  missingSubjectBatch.set(doc(
    adminDb,
    `users/${actors.secondApplicant}/memberships/station-a`,
  ), {
    role: 'beneficiary',
    active: true,
    subjectId: 'missing-beneficiary',
    assignedAt: serverTimestamp(),
    assignedBy: rootAdminUid,
  });
  missingSubjectBatch.update(doc(adminDb, `accessRequests/${actors.secondApplicant}`), {
    status: 'approved',
    reviewedAt: serverTimestamp(),
    reviewedBy: rootAdminUid,
  });
  await assertFails(missingSubjectBatch.commit());

  const invalidRoleBatch = writeBatch(adminDb);
  invalidRoleBatch.set(doc(adminDb, `users/${actors.secondApplicant}`), {
    email: 'second@example.com',
    displayName: 'مستخدم ثان',
    createdAt: serverTimestamp(),
  });
  invalidRoleBatch.set(doc(
    adminDb,
    `users/${actors.secondApplicant}/memberships/station-a`,
  ), {
    role: 'superadmin',
    active: true,
    assignedAt: serverTimestamp(),
    assignedBy: rootAdminUid,
  });
  invalidRoleBatch.update(doc(adminDb, `accessRequests/${actors.secondApplicant}`), {
    status: 'approved',
    reviewedAt: serverTimestamp(),
    reviewedBy: rootAdminUid,
  });
  await assertFails(invalidRoleBatch.commit());

  await assertSucceeds(updateDoc(applicantMembership, {
    active: false,
    assignedAt: serverTimestamp(),
    assignedBy: rootAdminUid,
  }));
  await assertFails(getDoc(doc(applicantDb, 'stations/station-a/beneficiaries/beneficiary-1')));
});

test('non-admins and unverified superadmin cannot provision stations or memberships', async () => {
  const regularDb = signedIn(actors.manager);
  await assertFails(setDoc(doc(regularDb, 'stations/forged-station'), {
    name: 'محطة مزورة',
    active: true,
    createdAt: serverTimestamp(),
    createdBy: actors.manager,
  }));

  const unverifiedAdminDb = signedIn(rootAdminUid, {
    email: 'owner@example.com',
    email_verified: false,
  });
  await assertFails(getDocs(collection(unverifiedAdminDb, 'accessRequests')));
  await assertFails(setDoc(doc(unverifiedAdminDb, 'stations/unverified-station'), {
    name: 'مرفوضة',
    active: true,
    createdAt: serverTimestamp(),
    createdBy: rootAdminUid,
  }));
});
