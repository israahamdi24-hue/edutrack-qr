const crypto = require('node:crypto');

const prefix = 'edutrack:v1:';

function createAttendanceToken({
  sessionId,
  courseId,
  expiresAt,
  secret,
  now = Date.now(),
}) {
  if (
    typeof sessionId !== 'string' ||
    sessionId.length === 0 ||
    sessionId.length > 256 ||
    sessionId.includes('/') ||
    typeof courseId !== 'string' ||
    courseId.length === 0 ||
    courseId.length > 256 ||
    courseId.includes('/') ||
    !Number.isSafeInteger(expiresAt) ||
    expiresAt <= now ||
    typeof secret !== 'string' ||
    Buffer.byteLength(secret, 'utf8') < 32
  ) {
    throw new TypeError('Invalid attendance token parameters.');
  }

  const payload = {
    v: 1,
    sessionId,
    courseId,
    issuedAt: now,
    expiresAt,
    nonce: crypto.randomBytes(16).toString('base64url'),
  };
  const encoded = Buffer.from(JSON.stringify(payload)).toString('base64url');
  const signature = crypto
    .createHmac('sha256', secret)
    .update(encoded)
    .digest('base64url');
  return `${prefix}${encoded}.${signature}`;
}

function verifyAttendanceToken(
  token,
  secret,
  now = Date.now(),
  allowExpired = false,
) {
  if (
    typeof token !== 'string' ||
    token.length > 2048 ||
    typeof secret !== 'string' ||
    Buffer.byteLength(secret, 'utf8') < 32
  ) {
    return null;
  }
  const match = /^edutrack:v1:([A-Za-z0-9_-]+)\.([A-Za-z0-9_-]+)$/.exec(
    token,
  );
  if (!match) return null;

  const [, encoded, providedSignature] = match;
  const expectedSignature = crypto
    .createHmac('sha256', secret)
    .update(encoded)
    .digest();
  const actualSignature = Buffer.from(providedSignature, 'base64url');
  if (
    actualSignature.length !== expectedSignature.length ||
    !crypto.timingSafeEqual(actualSignature, expectedSignature)
  ) {
    return null;
  }

  try {
    const payload = JSON.parse(
      Buffer.from(encoded, 'base64url').toString('utf8'),
    );
    if (
      payload.v !== 1 ||
      typeof payload.sessionId !== 'string' ||
      payload.sessionId.length === 0 ||
      payload.sessionId.length > 256 ||
      payload.sessionId.includes('/') ||
      typeof payload.courseId !== 'string' ||
      payload.courseId.length === 0 ||
      payload.courseId.length > 256 ||
      payload.courseId.includes('/') ||
      !Number.isSafeInteger(payload.issuedAt) ||
      !Number.isSafeInteger(payload.expiresAt) ||
      payload.issuedAt > now ||
      payload.expiresAt <= payload.issuedAt ||
      (!allowExpired && payload.expiresAt <= now) ||
      typeof payload.nonce !== 'string' ||
      !/^[A-Za-z0-9_-]{22}$/.test(payload.nonce)
    ) {
      return null;
    }
    return payload;
  } catch {
    return null;
  }
}

module.exports = { createAttendanceToken, verifyAttendanceToken };
