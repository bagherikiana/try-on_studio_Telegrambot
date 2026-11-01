// Gives the n8n_app role a random password, enables login and checks it works.
// Usage: npm run db:app-password               -> first time: saves N8N_DATABASE_URL to .env.n8n.local
//        npm run db:app-password -- --rotate   -> replace an existing password (then update n8n!)
//        npm run db:app-password -- --no-save  -> only check (for test branches)
// The password is never printed.
const crypto = require('crypto');
const fs = require('fs');
const {
  N8N_ENV_FILE, loadEnv, usingShellUrls, directUrl, pooledUrl, secureUrl, withClient,
} = require('./lib/db');

const ROLE = 'n8n_app';

async function main() {
  const save = !process.argv.includes('--no-save');
  // Without saving, the new password is lost: only allowed on a test branch.
  if (!save && !usingShellUrls()) {
    throw new Error('--no-save is only for test branches: set DATABASE_URL and DATABASE_URL_UNPOOLED in the shell.');
  }
  if (save && loadEnv().N8N_DATABASE_URL && !process.argv.includes('--rotate')) {
    throw new Error('N8N_DATABASE_URL already exists. Use --rotate to replace it, then update the n8n credential.');
  }

  const password = crypto.randomBytes(24).toString('base64url');
  await withClient(directUrl(), (admin) =>
    admin.query(`ALTER ROLE ${ROLE} WITH LOGIN PASSWORD ${admin.escapeLiteral(password)}`));

  // n8n uses the pooled endpoint with the app login.
  const appUrl = new URL(secureUrl(pooledUrl()));
  appUrl.username = ROLE;
  appUrl.password = password;

  const { rows } = await withClient(appUrl.toString(), (app) =>
    app.query('SELECT current_user, count(*)::int AS settings FROM settings'));
  console.log(`login ok as ${rows[0].current_user}, can read ${rows[0].settings} settings`);

  if (save) {
    fs.writeFileSync(N8N_ENV_FILE, `N8N_DATABASE_URL="${appUrl}"\n`);
    console.log('saved N8N_DATABASE_URL to .env.n8n.local');
  }
}

main().catch((err) => { console.error(err.message); process.exit(1); });
