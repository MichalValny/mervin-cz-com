export function corsHeaders(origin, allowedOrigins) {
  const normalized = allowedOrigins.includes(origin) ? origin : allowedOrigins[0] ?? '*';
  return {
    'Access-Control-Allow-Origin': normalized,
    'Access-Control-Allow-Headers': 'authorization,content-type',
    'Access-Control-Allow-Methods': 'GET,POST,OPTIONS',
    'Access-Control-Max-Age': '86400',
  };
}

export function jsonResponse(statusCode, body, origin, allowedOrigins, extraHeaders = {}) {
  return {
    statusCode,
    headers: {
      'Content-Type': 'application/json; charset=utf-8',
      ...corsHeaders(origin, allowedOrigins),
      ...extraHeaders,
    },
    body: JSON.stringify(body),
  };
}
