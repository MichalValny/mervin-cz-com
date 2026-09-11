const DEFAULT_MAX_FILES = 100;
const DEFAULT_MAX_FILE_BYTES = 15 * 1024 * 1024;

export function getConfig() {
  const allowedOrigins = (process.env.UPLOAD_ALLOWED_ORIGINS ?? 'https://www.mervin-cz.com,https://mervin-cz.com,https://d3k6t1hocigyks.cloudfront.net,http://localhost:4321')
    .split(',')
    .map((origin) => origin.trim())
    .filter(Boolean);

  return {
    bucket: process.env.UPLOAD_S3_BUCKET ?? 'web-mervin-cz-com',
    prefix: process.env.UPLOAD_S3_PREFIX ?? 'uploads-staging',
    jwtSecret: process.env.UPLOAD_JWT_SECRET,
    passwords: {
      Michal: process.env.UPLOAD_PASSWORD_MICHAL,
      Horak: process.env.UPLOAD_PASSWORD_HORAK,
    },
    githubToken: process.env.UPLOAD_GITHUB_TOKEN?.trim(),
    githubRepo: process.env.GITHUB_UPLOAD_REPO ?? 'MichalValny/mervin-cz-com',
    allowedOrigins,
    maxFiles: Number(process.env.UPLOAD_MAX_FILES ?? DEFAULT_MAX_FILES),
    maxFileBytes: Number(process.env.UPLOAD_MAX_FILE_BYTES ?? DEFAULT_MAX_FILE_BYTES),
  };
}

export function validateConfig(config) {
  const missing = [];
  if (!config.jwtSecret) missing.push('UPLOAD_JWT_SECRET');
  if (!config.passwords.Michal) missing.push('UPLOAD_PASSWORD_MICHAL');
  if (!config.passwords.Horak) missing.push('UPLOAD_PASSWORD_HORAK');
  if (!config.githubToken) missing.push('UPLOAD_GITHUB_TOKEN');
  return missing;
}
