# Try-On Bot

A Telegram bot for **virtual clothing try-on**, built on **n8n Cloud**, **Neon PostgreSQL** and an OpenAI-compatible image-editing API (currently **GapGPT**). A user sends a photo of themselves and a photo of a garment; the bot returns a photorealistic image of the same person wearing that garment.

Adults only (18+ confirmation required). Bot messages are in Persian.

## How it works

| Part | What it does |
|---|---|
| `Try-On Bot · 1 · Gateway & Onboarding` (n8n) | Receives every Telegram update, registers the user, shows the terms and 18+ confirmation, routes photos, answers everything else |
| `Try-On Bot · 2 · Photo & Try-On` (n8n) | Validates and saves photos; for a garment photo it checks the quota, calls the image API, sends the result and records the job |
| Neon `tryon` schema | Users, photos, catalog, jobs, settings. Quota, 18+ and abuse checks run inside `tryon.start_job`, so n8n cannot bypass them |

## Repository layout

```
db/migrations/   SQL migrations, applied in order by npm run db:migrate
scripts/         migrate.js, set-app-password.js, set-setting.js
n8n/code/        source of the n8n Code nodes (kept in sync by hand)
n8n/workflows/   exported n8n workflows (no secrets, credential names only)
```

## Setup

Requires Node.js 20.12 or newer (the scripts use `util.parseEnv`).

1. **Neon:** create a project, then `npx neonctl env pull` to write `.env.local` (git-ignored).
2. **Database:**
   ```bash
   npm install
   npm run db:migrate
   npm run db:app-password      # creates the n8n_app login, saved to .env.n8n.local
   npm run db:set admin_chat_id <your Telegram chat id>
   ```
3. **n8n credentials** (created in n8n, never in this repo):
   - Telegram API: your bot token from BotFather
   - Postgres: user `n8n_app`, database `neondb`, SSL `require`, password from `.env.n8n.local`
   - Bearer Auth: your image API key (GapGPT)
4. **Import** the two files in `n8n/workflows/`, attach the credentials, then publish workflow 2 and workflow 1.

## Configuration

Runtime settings live in `tryon.settings` and are changed without a migration:

```bash
npm run db:set ai_model gapgpt/qwen-image-2.1
npm run db:set daily_limit 5
```

## Security

- No secrets in git: `.env.local`, `.env.n8n.local` and `.neon` are ignored; API keys and tokens exist only as n8n credentials.
- n8n uses a least-privilege database role (`n8n_app`) that cannot create jobs directly, unblock users or change settings.
- Photos are downloaded inside n8n; Telegram file links (which contain the bot token) are never sent to third parties.
