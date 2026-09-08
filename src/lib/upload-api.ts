import uploadApiJson from '../data/upload-api.json';

const EXECUTE_API_PATTERN = /^https:\/\/[a-z0-9]+\.execute-api\.[a-z0-9-]+\.amazonaws\.com$/;

function normalizeUrl(value: string): string {
  return value.trim().replace(/\/$/, '');
}

function isValidExecuteApiUrl(value: string): boolean {
  return EXECUTE_API_PATTERN.test(value);
}

/** Prefer committed deploy config over GitHub env (avoids typos in variables). */
export function resolveUploadApiUrl(): string {
  const fromFile = normalizeUrl(uploadApiJson.apiUrl ?? '');
  if (fromFile && isValidExecuteApiUrl(fromFile)) {
    return fromFile;
  }

  const fromEnv = normalizeUrl(import.meta.env.PUBLIC_UPLOAD_API_URL ?? '');
  if (fromEnv && isValidExecuteApiUrl(fromEnv)) {
    return fromEnv;
  }

  return fromFile || fromEnv;
}
