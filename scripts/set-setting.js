// Changes one runtime setting in tryon.settings without a migration.
// Usage: npm run db:set <key> <value>
//   npm run db:set admin_chat_id 123456789
//   npm run db:set ai_model gapgpt/qwen-image-2.1
//   npm run db:set daily_limit 5
// The value is stored as JSON: numbers stay numbers, anything else becomes a string.
// Only existing keys can be changed; the table's CHECK constraints validate the value.
const { directUrl, withClient } = require('./lib/db');

const [key, raw] = process.argv.slice(2);

async function main() {
  if (!key || raw === undefined) throw new Error('Usage: npm run db:set <key> <value>');
  const value = /^-?\d+(\.\d+)?$/.test(raw) && key !== 'admin_chat_id' ? Number(raw) : String(raw);

  const { rowCount } = await withClient(directUrl(), (c) =>
    c.query('UPDATE tryon.settings SET value = $2::jsonb WHERE key = $1', [key, JSON.stringify(value)]));
  if (rowCount === 0) throw new Error(`Unknown setting "${key}"`);
  console.log(`updated ${key}`);
}

main().catch((err) => { console.error(err.message); process.exit(1); });
