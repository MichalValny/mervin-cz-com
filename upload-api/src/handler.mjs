import crypto from 'node:crypto';
import { getConfig, validateConfig } from './config.mjs';
import { createSessionToken, readBearerToken, verifyCredentials, verifySessionToken } from './auth.mjs';
import { triggerUploadWorkflow } from './github.mjs';
import {
  buildPhotoKey,
  createPresignedPutUrl,
  getJson,
  objectExists,
  putJson,
  uploadPrefix,
} from './s3.mjs';
import { corsHeaders, jsonResponse } from './cors.mjs';

function parseBody(event) {
  if (!event.body) {
    return null;
  }
  const raw = event.isBase64Encoded
    ? Buffer.from(event.body, 'base64').toString('utf8')
    : event.body;
  try {
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

function getPath(event) {
  return event.rawPath ?? event.path ?? '/';
}

function requireUser(event, config) {
  const token = readBearerToken(event.headers ?? {});
  if (!token) {
    return { error: jsonResponse(401, { error: 'Chybí přihlášení.' }, event.headers?.origin, config.allowedOrigins) };
  }
  const username = verifySessionToken(token, config.jwtSecret);
  if (!username) {
    return { error: jsonResponse(401, { error: 'Platnost přihlášení vypršela. Přihlaste se znovu.' }, event.headers?.origin, config.allowedOrigins) };
  }
  return { username };
}

function validateSubmitPayload(body, config) {
  const title = String(body?.title ?? '').trim();
  const categorySlug = String(body?.categorySlug ?? '').trim();
  const date = String(body?.date ?? '').trim();
  const text = String(body?.text ?? '').trim();
  const galleryTitle = String(body?.galleryTitle ?? '').trim();
  const files = Array.isArray(body?.files) ? body.files : [];

  if (!title || title.length < 3) {
    return { error: 'Vyplňte nadpis článku (alespoň 3 znaky).' };
  }
  if (!categorySlug) {
    return { error: 'Vyberte rubriku.' };
  }
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) {
    return { error: 'Vyplňte platné datum.' };
  }
  if (!text) {
    return { error: 'Vyplňte text článku.' };
  }
  if (files.length === 0) {
    return { error: 'Přidejte alespoň jednu fotografii.' };
  }
  if (files.length > config.maxFiles) {
    return { error: `Maximum je ${config.maxFiles} fotografií.` };
  }

  for (const file of files) {
    const name = String(file?.name ?? '').trim();
    const size = Number(file?.size ?? 0);
    const type = String(file?.type ?? '').trim();
    if (!name) {
      return { error: 'Každá fotografie musí mít název souboru.' };
    }
    if (!Number.isFinite(size) || size <= 0) {
      return { error: `Neplatná velikost souboru: ${name}` };
    }
    if (size > config.maxFileBytes) {
      return { error: `Soubor ${name} je příliš velký (max ${Math.round(config.maxFileBytes / (1024 * 1024))} MB).` };
    }
    if (!type.startsWith('image/')) {
      return { error: `Soubor ${name} není obrázek.` };
    }
  }

  return {
    value: {
      title,
      categorySlug,
      date,
      text,
      galleryTitle: galleryTitle || title,
      files: files.map((file) => ({
        name: String(file.name).trim(),
        size: Number(file.size),
        type: String(file.type).trim(),
      })),
    },
  };
}

async function handleLogin(event, config) {
  const body = parseBody(event);
  const username = String(body?.username ?? '').trim();
  const password = String(body?.password ?? '');

  if (!verifyCredentials(username, password, config.passwords)) {
    return jsonResponse(401, { error: 'Neplatné jméno nebo heslo.' }, event.headers?.origin, config.allowedOrigins);
  }

  const token = createSessionToken(username, config.jwtSecret);
  return jsonResponse(200, {
    token,
    username,
    expiresInHours: 8,
  }, event.headers?.origin, config.allowedOrigins);
}

async function handlePrepare(event, config) {
  const auth = requireUser(event, config);
  if (auth.error) {
    return auth.error;
  }

  const body = parseBody(event);
  const validated = validateSubmitPayload(body, config);
  if (validated.error) {
    return jsonResponse(400, { error: validated.error }, event.headers?.origin, config.allowedOrigins);
  }

  const uploadId = crypto.randomUUID();
  const prefix = uploadPrefix(config.prefix, uploadId);
  const uploadMeta = {
    uploadId,
    author: auth.username,
    createdAt: new Date().toISOString(),
    ...validated.value,
    photoKeys: [],
  };

  const uploads = [];
  for (let index = 0; index < validated.value.files.length; index += 1) {
    const file = validated.value.files[index];
    const key = buildPhotoKey(config.prefix, uploadId, index + 1, file.name);
    uploadMeta.photoKeys.push(key);
    uploads.push({
      key,
      url: await createPresignedPutUrl(config.bucket, key, file.type),
      name: file.name,
      contentType: file.type,
    });
  }

  await putJson(config.bucket, `${prefix}/meta.json`, uploadMeta);

  return jsonResponse(200, {
    uploadId,
    uploads,
  }, event.headers?.origin, config.allowedOrigins);
}

async function handleComplete(event, config) {
  const auth = requireUser(event, config);
  if (auth.error) {
    return auth.error;
  }

  const body = parseBody(event);
  const uploadId = String(body?.uploadId ?? '').trim();
  if (!uploadId) {
    return jsonResponse(400, { error: 'Chybí identifikátor uploadu.' }, event.headers?.origin, config.allowedOrigins);
  }

  const metaKey = `${uploadPrefix(config.prefix, uploadId)}/meta.json`;
  if (!(await objectExists(config.bucket, metaKey))) {
    return jsonResponse(404, { error: 'Upload nebyl nalezen.' }, event.headers?.origin, config.allowedOrigins);
  }

  const meta = await getJson(config.bucket, metaKey);
  if (meta.author !== auth.username) {
    return jsonResponse(403, { error: 'Nemáte oprávnění dokončit tento upload.' }, event.headers?.origin, config.allowedOrigins);
  }

  for (const key of meta.photoKeys ?? []) {
    if (!(await objectExists(config.bucket, key))) {
      return jsonResponse(400, { error: 'Některé fotografie ještě nebyly nahrány. Zkuste to znovu.' }, event.headers?.origin, config.allowedOrigins);
    }
  }

  meta.completedAt = new Date().toISOString();
  meta.status = 'ready';
  await putJson(config.bucket, metaKey, meta);

  try {
    await triggerUploadWorkflow({
      token: config.githubToken,
      repo: config.githubRepo,
      workflow: config.githubWorkflow,
      uploadId,
      author: auth.username,
    });
  } catch (error) {
    console.error('GitHub workflow dispatch failed:', error);
    const message = error instanceof Error ? error.message : 'Nepodařilo se spustit GitHub workflow.';
    return jsonResponse(502, {
      error: 'Nepodařilo se odeslat příspěvek ke schválení. Zkontrolujte UPLOAD_GITHUB_TOKEN v GitHub Secrets a znovu spusťte Bootstrap AWS.',
      detail: message,
    }, event.headers?.origin, config.allowedOrigins);
  }

  return jsonResponse(200, {
    ok: true,
    message: 'Příspěvek byl odeslán ke schválení. Po schválení se objeví na webu.',
    uploadId,
  }, event.headers?.origin, config.allowedOrigins);
}

async function handleMe(event, config) {
  const auth = requireUser(event, config);
  if (auth.error) {
    return auth.error;
  }
  return jsonResponse(200, { username: auth.username }, event.headers?.origin, config.allowedOrigins);
}

export async function handler(event) {
  const config = getConfig();
  const origin = event.headers?.origin ?? event.headers?.Origin ?? '';
  const method = event.requestContext?.http?.method ?? event.httpMethod ?? 'GET';
  const path = getPath(event);

  try {
    return await routeRequest(event, config, origin, method, path);
  } catch (error) {
    console.error('Unhandled upload API error:', error);
    const message = error instanceof Error ? error.message : 'Neočekávaná chyba upload API.';
    return jsonResponse(500, {
      error: 'Interní chyba upload služby.',
      detail: message,
    }, origin, config.allowedOrigins);
  }
}

async function routeRequest(event, config, origin, method, path) {

  if (method === 'OPTIONS') {
    return {
      statusCode: 204,
      headers: corsHeaders(origin, config.allowedOrigins),
      body: '',
    };
  }

  const missing = validateConfig(config);
  if (missing.length > 0) {
    return jsonResponse(503, {
      error: 'Upload služba není nakonfigurovaná.',
      missing,
    }, origin, config.allowedOrigins);
  }

  if (path.endsWith('/login') && method === 'POST') {
    return handleLogin(event, config);
  }
  if (path.endsWith('/prepare') && method === 'POST') {
    return handlePrepare(event, config);
  }
  if (path.endsWith('/complete') && method === 'POST') {
    return handleComplete(event, config);
  }
  if (path.endsWith('/me') && method === 'GET') {
    return handleMe(event, config);
  }

  return jsonResponse(404, { error: 'Endpoint nenalezen.' }, origin, config.allowedOrigins);
}
