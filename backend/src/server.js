const { applicationDefault, cert, initializeApp } = require('firebase-admin/app');
const { getAuth } = require('firebase-admin/auth');
const { getFirestore } = require('firebase-admin/firestore');
const { createApp } = require('./app');

const signingSecret = process.env.EDUTRACK_QR_SIGNING_SECRET;
if (typeof signingSecret !== 'string' || Buffer.byteLength(signingSecret, 'utf8') < 32) {
  throw new Error('EDUTRACK_QR_SIGNING_SECRET must contain at least 32 bytes.');
}

const projectId = process.env.FIREBASE_PROJECT_ID;
let credential = applicationDefault();
if (process.env.FIREBASE_SERVICE_ACCOUNT_JSON) {
  let serviceAccount;
  try {
    serviceAccount = JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT_JSON);
  } catch {
    throw new Error('FIREBASE_SERVICE_ACCOUNT_JSON must contain valid JSON.');
  }
  if (!serviceAccount.project_id || !serviceAccount.private_key || !serviceAccount.client_email) {
    throw new Error('FIREBASE_SERVICE_ACCOUNT_JSON is missing required service account fields.');
  }
  credential = cert(serviceAccount);
}

initializeApp({
  credential,
  ...(projectId ? { projectId } : {}),
});

const allowedOrigins = (process.env.CORS_ALLOWED_ORIGINS ?? '')
  .split(',')
  .map((origin) => origin.trim())
  .filter(Boolean);
if (process.env.NODE_ENV === 'production' && allowedOrigins.length === 0) {
  throw new Error('CORS_ALLOWED_ORIGINS must be configured in production.');
}
const app = createApp({
  auth: getAuth(),
  db: getFirestore(),
  signingSecret,
  allowedOrigins,
  allowLocalNetworkOrigins: process.env.NODE_ENV !== 'production',
});
const port = Number(process.env.PORT ?? 3000);
if (!Number.isInteger(port) || port < 1 || port > 65535) {
  throw new Error('PORT must be a valid TCP port.');
}

app.listen(port, '0.0.0.0', () => {
  console.log(`EduTrack API listening on port ${port}`);
});
