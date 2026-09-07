import { PutObjectCommand, GetObjectCommand, HeadObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { getSignedUrl } from '@aws-sdk/s3-request-presigner';

const s3 = new S3Client({});

export async function putJson(bucket, key, value) {
  await s3.send(new PutObjectCommand({
    Bucket: bucket,
    Key: key,
    Body: JSON.stringify(value, null, 2),
    ContentType: 'application/json; charset=utf-8',
  }));
}

export async function getJson(bucket, key) {
  const response = await s3.send(new GetObjectCommand({ Bucket: bucket, Key: key }));
  const body = await response.Body.transformToString();
  return JSON.parse(body);
}

export async function objectExists(bucket, key) {
  try {
    await s3.send(new HeadObjectCommand({ Bucket: bucket, Key: key }));
    return true;
  } catch {
    return false;
  }
}

export async function createPresignedPutUrl(bucket, key, contentType, expiresIn = 900) {
  const command = new PutObjectCommand({
    Bucket: bucket,
    Key: key,
    ContentType: contentType,
  });
  return getSignedUrl(s3, command, { expiresIn });
}

export function uploadPrefix(prefix, uploadId) {
  return `${prefix}/${uploadId}`;
}

export function sanitizeFileName(name) {
  return String(name)
    .replace(/[^a-zA-Z0-9._-]+/g, '-')
    .replace(/-+/g, '-')
    .replace(/^-|-$/g, '')
    .slice(0, 80) || 'photo.jpg';
}

export function buildPhotoKey(prefix, uploadId, index, fileName) {
  const safeName = sanitizeFileName(fileName);
  const ext = safeName.includes('.') ? safeName.split('.').pop()?.toLowerCase() : 'jpg';
  const allowed = new Set(['jpg', 'jpeg', 'png', 'webp', 'heic', 'heif']);
  const normalizedExt = allowed.has(ext ?? '') ? ext : 'jpg';
  return `${uploadPrefix(prefix, uploadId)}/photos/${String(index).padStart(3, '0')}.${normalizedExt}`;
}
