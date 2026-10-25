import { createFirebaseTokenVerifier } from './firebase_auth.js';
import { createFirestoreDirectory } from './firestore_rest.js';
import { createHandler } from './handler.js';

const verifierCache = new Map();
const directoryCache = new Map();

function getVerifier(projectId) {
  let verifier = verifierCache.get(projectId);
  if (!verifier) {
    verifier = createFirebaseTokenVerifier({ projectId });
    verifierCache.set(projectId, verifier);
  }
  return verifier;
}

function getDirectory(projectId) {
  let directory = directoryCache.get(projectId);
  if (!directory) {
    directory = createFirestoreDirectory({ projectId });
    directoryCache.set(projectId, directory);
  }
  return directory;
}

export default {
  async fetch(request, env) {
    const projectId = env.FIREBASE_PROJECT_ID;
    const verifyFirebaseIdToken =
      typeof projectId === 'string' && projectId.length > 0
        ? getVerifier(projectId)
        : async () => {
            throw new Error('firebase_project_id_not_configured');
          };
    const firestore = getDirectory(projectId);
    firestore.setServiceAccountJson(env.FIREBASE_SERVICE_ACCOUNT_JSON);
    return createHandler({ verifyFirebaseIdToken, firestore })(request, env);
  },
};

export { createHandler } from './handler.js';
export { createFirebaseTokenVerifier } from './firebase_auth.js';
export { createFirestoreDirectory, FirestoreRestError } from './firestore_rest.js';
