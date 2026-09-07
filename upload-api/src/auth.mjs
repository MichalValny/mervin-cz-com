import crypto from 'node:crypto';
import jwt from 'jsonwebtoken';

function timingSafeEqualString(a, b) {
  const left = Buffer.from(String(a));
  const right = Buffer.from(String(b));
  if (left.length !== right.length) {
    return false;
  }
  return crypto.timingSafeEqual(left, right);
}

export function verifyCredentials(username, password, passwords) {
  const expected = passwords[username];
  if (!expected || !password) {
    return false;
  }
  return timingSafeEqualString(password, expected);
}

export function createSessionToken(username, jwtSecret) {
  return jwt.sign({ sub: username }, jwtSecret, { expiresIn: '8h' });
}

export function verifySessionToken(token, jwtSecret) {
  try {
    const payload = jwt.verify(token, jwtSecret);
    if (typeof payload.sub !== 'string' || !payload.sub) {
      return null;
    }
    return payload.sub;
  } catch {
    return null;
  }
}

export function readBearerToken(headers) {
  const auth = headers.authorization ?? headers.Authorization;
  if (!auth || typeof auth !== 'string') {
    return null;
  }
  const match = auth.match(/^Bearer\s+(.+)$/i);
  return match?.[1] ?? null;
}
