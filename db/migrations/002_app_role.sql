-- 002_app_role: least-privilege login used by n8n.
-- Created with SQL (not the Neon console) so it is NOT a member of neon_superuser.
-- The password is set separately by scripts/set-app-password.js and never stored in git.

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'n8n_app') THEN
    CREATE ROLE n8n_app NOLOGIN;
  END IF;
END $$;

GRANT USAGE ON SCHEMA tryon TO n8n_app;

-- users: n8n manages profile and conversation fields only.
-- is_blocked and daily_limit stay admin-only.
GRANT SELECT ON tryon.users TO n8n_app;
GRANT INSERT (telegram_user_id, chat_id, username, first_name, language_code)
  ON tryon.users TO n8n_app;
GRANT UPDATE (chat_id, username, first_name, language_code, age_confirmed_at,
              terms_version, state, state_data, last_seen_at)
  ON tryon.users TO n8n_app;

GRANT SELECT, INSERT ON tryon.photos, tryon.error_logs TO n8n_app;
-- Jobs are read-only: they change only through the functions below.
GRANT SELECT ON tryon.tryon_jobs, tryon.garments, tryon.settings TO n8n_app;

GRANT EXECUTE ON FUNCTION
  tryon.start_job(bigint, bigint, bigint, bigint, text),
  tryon.finish_job(bigint, boolean, text, text, text, jsonb, integer),
  tryon.fail_stale_jobs(interval)
TO n8n_app;

-- Safety limits for this login.
ALTER ROLE n8n_app SET statement_timeout = '15s';
ALTER ROLE n8n_app SET search_path = tryon;
