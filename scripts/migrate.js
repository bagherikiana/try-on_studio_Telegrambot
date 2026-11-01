// Applies db/migrations/*.sql in order, each once, each in its own transaction.
// Usage: npm run db:migrate
const fs = require('fs');
const path = require('path');
const { ROOT, directUrl, withClient } = require('./lib/db');

const DIR = path.join(ROOT, 'db', 'migrations');

async function migrate(client) {
  // One migration run at a time; released when the connection closes.
  await client.query("SELECT pg_advisory_lock(hashtext('tryon_migrations'))");
  await client.query(`CREATE TABLE IF NOT EXISTS public.schema_migrations (
    version text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())`);
  const { rows } = await client.query('SELECT version FROM public.schema_migrations');
  const applied = new Set(rows.map((r) => r.version));

  const files = fs.readdirSync(DIR).filter((f) => f.endsWith('.sql')).sort();
  for (const file of files) {
    if (applied.has(file)) continue;
    await client.query('BEGIN');
    try {
      await client.query(fs.readFileSync(path.join(DIR, file), 'utf8'));
      await client.query('INSERT INTO public.schema_migrations (version) VALUES ($1)', [file]);
      await client.query('COMMIT');
      console.log(`applied ${file}`);
    } catch (err) {
      await client.query('ROLLBACK');
      throw new Error(`${file}: ${err.message}`);
    }
  }
  console.log('migrations up to date');
}

Promise.resolve()
  .then(() => withClient(directUrl(), migrate))
  .catch((err) => { console.error(err.message); process.exit(1); });
