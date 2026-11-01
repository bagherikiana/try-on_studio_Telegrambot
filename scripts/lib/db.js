// Shared helpers for the admin scripts.
// Env comes from .env.local (written by `neon env pull`), .env.n8n.local (written by
// set-app-password.js) and process.env, which wins. To target another Neon branch,
// set DATABASE_URL / DATABASE_URL_UNPOOLED in the shell.
const fs = require('fs');
const path = require('path');
const { parseEnv } = require('util');
const { Client } = require('pg');

const ROOT = path.join(__dirname, '..', '..');
const N8N_ENV_FILE = path.join(ROOT, '.env.n8n.local');

const URL_VARS = ['DATABASE_URL', 'DATABASE_URL_UNPOOLED'];

// True when the shell points the scripts at a branch other than .env.local.
const usingShellUrls = () => URL_VARS.some((name) => process.env[name]);

function loadEnv() {
  const env = {};
  for (const file of [path.join(ROOT, '.env.local'), N8N_ENV_FILE]) {
    if (fs.existsSync(file)) Object.assign(env, parseEnv(fs.readFileSync(file, 'utf8')));
  }
  // Both connection strings must come from the same place, never one from each.
  if (usingShellUrls()) {
    const missing = URL_VARS.filter((name) => !process.env[name]);
    if (missing.length) throw new Error(`Set ${missing.join(' and ')} in the shell too, or neither`);
  }
  return { ...env, ...process.env };
}

function requireUrl(name, pooled) {
  const url = loadEnv()[name];
  if (!url) throw new Error(`${name} is not set (run: npx neonctl env pull)`);
  if (new URL(url).hostname.includes('-pooler') !== pooled) {
    throw new Error(`${name} must be the ${pooled ? 'pooled' : 'direct'} connection string`);
  }
  return url;
}

// Migrations and admin work use the direct connection; the app uses the pooled one.
const directUrl = () => requireUrl('DATABASE_URL_UNPOOLED', false);
const pooledUrl = () => requireUrl('DATABASE_URL', true);

// Always verify the server certificate and hostname.
function secureUrl(url) {
  const u = new URL(url);
  u.searchParams.set('sslmode', 'verify-full');
  return u.toString();
}

async function withClient(url, fn) {
  const client = new Client({ connectionString: secureUrl(url) });
  await client.connect();
  try {
    return await fn(client);
  } finally {
    await client.end();
  }
}

module.exports = {
  ROOT, N8N_ENV_FILE, loadEnv, usingShellUrls, directUrl, pooledUrl, secureUrl, withClient,
};
