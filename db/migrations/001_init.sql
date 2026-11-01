-- 001_init: core schema for the Virtual Try-On Telegram bot.
-- Photos are never stored here: only Telegram file_ids.

CREATE SCHEMA IF NOT EXISTS tryon;

-- Functions created by the owner are not executable by everyone by default.
-- Must be global: per-schema default privileges cannot revoke the built-in PUBLIC grant.
-- So any function neondb_owner creates in ANY schema needs an explicit GRANT EXECUTE.
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;

-- Keeps updated_at current on every UPDATE.
CREATE OR REPLACE FUNCTION tryon.touch_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

-- ---------------------------------------------------------------------------
-- settings: runtime config read by n8n (model name, limits, prompt).
-- Changing a value here changes bot behaviour without editing workflows.
-- ---------------------------------------------------------------------------
CREATE TABLE tryon.settings (
  key         text PRIMARY KEY,
  value       jsonb NOT NULL,
  description text,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  -- Bad values would break every try-on, so reject them on write.
  -- CASE fixes the evaluation order so a cast never runs on the wrong key.
  CHECK (CASE
    WHEN key = 'daily_limit' THEN jsonb_typeof(value) = 'number'
                                  AND (value #>> '{}') ~ '^[0-9]{1,6}$'
    WHEN key = 'timezone'    THEN jsonb_typeof(value) = 'string'
                                  AND (now() AT TIME ZONE (value #>> '{}')) IS NOT NULL
    WHEN key IN ('ai_model', 'ai_prompt_version', 'terms_version')
                             THEN jsonb_typeof(value) = 'string' AND length(value #>> '{}') > 0
    ELSE true
  END)
);

CREATE TRIGGER settings_touch BEFORE UPDATE ON tryon.settings
  FOR EACH ROW EXECUTE FUNCTION tryon.touch_updated_at();

INSERT INTO tryon.settings (key, value, description) VALUES
  ('ai_model',          '"gpt-image-2"',    'AvalAI image model used for try-on'),
  ('ai_prompt_version', '"v1"',             'Prompt template version, logged on every job'),
  ('daily_limit',       '5',                'Default try-ons per user per day'),
  ('terms_version',     '"2026-10-31"',     'Current terms users must accept'),
  ('timezone',          '"Asia/Tehran"',    'Timezone that defines "today" for the daily limit');

-- ---------------------------------------------------------------------------
-- users: one row per Telegram user, including conversation step.
-- Whether a job is running is NOT stored here: it comes from tryon_jobs.
-- ---------------------------------------------------------------------------
CREATE TABLE tryon.users (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  telegram_user_id  bigint NOT NULL UNIQUE,
  chat_id           bigint NOT NULL,
  username          text,
  first_name        text,
  language_code     text,
  -- 18+ confirmation and accepted terms; NULL means not confirmed yet.
  age_confirmed_at  timestamptz,
  terms_version     text,
  -- Where the user is in the bot conversation.
  state             text NOT NULL DEFAULT 'NEW'
                    CHECK (state IN ('NEW', 'AWAIT_AGE_CONFIRM', 'AWAIT_PERSON_PHOTO',
                                     'AWAIT_GARMENT', 'IDLE')),
  -- Small per-step data, e.g. {"person_photo_id": 12}.
  state_data        jsonb NOT NULL DEFAULT '{}'::jsonb,
  -- Per-user override of settings.daily_limit; NULL uses the default.
  daily_limit       integer CHECK (daily_limit >= 0),
  is_blocked        boolean NOT NULL DEFAULT false,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  last_seen_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TRIGGER users_touch BEFORE UPDATE ON tryon.users
  FOR EACH ROW EXECUTE FUNCTION tryon.touch_updated_at();

-- ---------------------------------------------------------------------------
-- photos: photos users send (themselves or a garment). Telegram keeps the file.
-- ---------------------------------------------------------------------------
CREATE TABLE tryon.photos (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id           bigint NOT NULL REFERENCES tryon.users(id) ON DELETE CASCADE,
  kind              text NOT NULL CHECK (kind IN ('person', 'garment')),
  telegram_file_id  text NOT NULL,
  file_unique_id    text NOT NULL,
  width             integer,
  height            integer,
  file_size         integer,
  created_at        timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX photos_user_idx ON tryon.photos (user_id);

-- ---------------------------------------------------------------------------
-- garments: ready-made catalog shown as buttons in the bot.
-- ---------------------------------------------------------------------------
CREATE TABLE tryon.garments (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  sku               text NOT NULL UNIQUE,
  title             text NOT NULL,
  category          text NOT NULL
                    CHECK (category IN ('top', 'bottom', 'dress', 'outerwear', 'full_body')),
  audience          text NOT NULL DEFAULT 'unisex'
                    CHECK (audience IN ('women', 'men', 'unisex')),
  -- Catalog image uploaded to Telegram once; reused by file_id.
  telegram_file_id  text NOT NULL,
  is_active         boolean NOT NULL DEFAULT true,
  sort_order        integer NOT NULL DEFAULT 0,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX garments_active_idx ON tryon.garments (category, sort_order) WHERE is_active;

CREATE TRIGGER garments_touch BEFORE UPDATE ON tryon.garments
  FOR EACH ROW EXECUTE FUNCTION tryon.touch_updated_at();

-- ---------------------------------------------------------------------------
-- tryon_jobs: one row per try-on request. Source of truth for quota, cost
-- and "is this user busy". Written only through the functions below.
-- ---------------------------------------------------------------------------
CREATE TABLE tryon.tryon_jobs (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  user_id           bigint NOT NULL REFERENCES tryon.users(id) ON DELETE CASCADE,
  person_photo_id   bigint NOT NULL REFERENCES tryon.photos(id),
  -- Exactly one garment source: catalog item or user's own garment photo.
  garment_id        bigint REFERENCES tryon.garments(id),
  garment_photo_id  bigint REFERENCES tryon.photos(id),
  status            text NOT NULL DEFAULT 'processing'
                    CHECK (status IN ('processing', 'succeeded', 'failed')),
  model             text NOT NULL,
  prompt_version    text NOT NULL,
  attempts          smallint NOT NULL DEFAULT 0,
  result_file_id    text,
  error_code        text,
  error_message     text,
  -- Raw usage/cost info returned by the image provider.
  usage             jsonb,
  n8n_execution_id  text,
  created_at        timestamptz NOT NULL DEFAULT now(),
  finished_at       timestamptz,
  CHECK ((garment_id IS NULL) <> (garment_photo_id IS NULL)),
  CHECK (status <> 'succeeded' OR result_file_id IS NOT NULL)
);

-- At most one running job per user: blocks double taps and parallel spending.
CREATE UNIQUE INDEX tryon_jobs_one_active_idx
  ON tryon.tryon_jobs (user_id) WHERE status = 'processing';

-- Daily quota lookups (index-only thanks to INCLUDE).
CREATE INDEX tryon_jobs_user_created_idx ON tryon.tryon_jobs (user_id, created_at) INCLUDE (status);

-- ---------------------------------------------------------------------------
-- error_logs: for a future n8n error-handler workflow (not built yet).
-- ---------------------------------------------------------------------------
CREATE TABLE tryon.error_logs (
  id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  workflow_name     text,
  node_name         text,
  n8n_execution_id  text,
  user_id           bigint REFERENCES tryon.users(id) ON DELETE SET NULL,
  message           text NOT NULL,
  details           jsonb,
  created_at        timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX error_logs_created_idx ON tryon.error_logs (created_at DESC);

-- ---------------------------------------------------------------------------
-- Job functions. SECURITY DEFINER: they are the ONLY way n8n can create or
-- change jobs, so the checks below cannot be skipped.
-- ---------------------------------------------------------------------------

-- start_job: checks block, age, input, config, running job and daily quota,
-- then creates the job. Returns ok=false with a reason the bot turns into a message.
CREATE OR REPLACE FUNCTION tryon.start_job(
  p_user_id          bigint,
  p_person_photo_id  bigint,
  p_garment_id       bigint,
  p_garment_photo_id bigint,
  p_execution_id     text
) RETURNS TABLE (ok boolean, reason text, job_id bigint, model text,
                 prompt_version text, used_today integer, daily_limit integer)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = tryon, pg_temp AS $$
#variable_conflict use_column
DECLARE
  u           record;
  cfg         jsonb;
  v_day_start timestamptz;
  v_active    boolean;
  v_photos    integer;
  v_reason    text;
  v_model     text;
  v_prompt    text;
  v_limit     integer;
  v_used      integer;
  v_job_id    bigint;
BEGIN
  -- Lock the user row so two requests from one user run one after another.
  SELECT us.is_blocked, us.age_confirmed_at, us.daily_limit AS user_limit INTO u
    FROM users us WHERE us.id = p_user_id FOR UPDATE;
  IF NOT FOUND THEN
    RETURN QUERY SELECT false, 'user_not_found'::text, NULL::bigint, NULL::text, NULL::text, 0, 0;
    RETURN;
  END IF;

  -- Missing settings fall back to safe values (limit 0 = no try-ons).
  SELECT jsonb_object_agg(s.key, s.value) INTO cfg FROM settings s;
  v_model     := cfg->>'ai_model';
  v_prompt    := COALESCE(cfg->>'ai_prompt_version', 'v1');
  v_limit     := COALESCE(u.user_limit, (cfg->>'daily_limit')::integer, 0);
  v_day_start := date_trunc('day', now() AT TIME ZONE COALESCE(cfg->>'timezone', 'UTC'))
                 AT TIME ZONE COALESCE(cfg->>'timezone', 'UTC');

  -- Today's usage (failed jobs do not count) and running job, in one scan.
  SELECT count(*) FILTER (WHERE j.status <> 'failed' AND j.created_at >= v_day_start)::integer,
         COALESCE(bool_or(j.status = 'processing'), false)
    INTO v_used, v_active
    FROM tryon_jobs j
   WHERE j.user_id = p_user_id AND (j.created_at >= v_day_start OR j.status = 'processing');

  -- The photos must belong to this user and be of the right kind.
  SELECT count(*)::integer INTO v_photos
    FROM photos p
   WHERE p.user_id = p_user_id
     AND ((p.id = p_person_photo_id AND p.kind = 'person')
       OR (p.id = p_garment_photo_id AND p.kind = 'garment'));

  v_reason := CASE
    WHEN u.is_blocked THEN 'blocked'
    WHEN u.age_confirmed_at IS NULL THEN 'age_not_confirmed'
    WHEN (p_garment_id IS NULL) = (p_garment_photo_id IS NULL)
      OR v_photos <> 1 + (p_garment_photo_id IS NOT NULL)::integer
      OR (p_garment_id IS NOT NULL
          AND NOT EXISTS (SELECT 1 FROM garments g WHERE g.id = p_garment_id AND g.is_active))
      THEN 'invalid_input'
    WHEN v_model IS NULL THEN 'config_error'
    WHEN v_active THEN 'job_in_progress'
    WHEN v_used >= v_limit THEN 'daily_limit_reached'
  END;

  IF v_reason IS NULL THEN
    INSERT INTO tryon_jobs (user_id, person_photo_id, garment_id, garment_photo_id,
                            model, prompt_version, n8n_execution_id)
    VALUES (p_user_id, p_person_photo_id, p_garment_id, p_garment_photo_id,
            v_model, v_prompt, p_execution_id)
    RETURNING id INTO v_job_id;
    v_used := v_used + 1;
  END IF;

  RETURN QUERY SELECT v_reason IS NULL, v_reason, v_job_id, v_model, v_prompt, v_used, v_limit;
END $$;

-- finish_job: marks a job succeeded or failed. Returns false if the job is
-- unknown or already finished, so calling it twice is safe.
-- "Succeeded" without a result file is recorded as failed, so a job never stays stuck.
CREATE OR REPLACE FUNCTION tryon.finish_job(
  p_job_id         bigint,
  p_succeeded      boolean,
  p_result_file_id text,
  p_error_code     text,
  p_error_message  text,
  p_usage          jsonb,
  p_attempts       integer
) RETURNS boolean
LANGUAGE sql SECURITY DEFINER SET search_path = tryon, pg_temp AS $$
  WITH done AS (
    UPDATE tryon_jobs
       SET status         = CASE WHEN p_succeeded AND p_result_file_id IS NOT NULL
                                 THEN 'succeeded' ELSE 'failed' END,
           result_file_id = p_result_file_id,
           error_code     = COALESCE(p_error_code,
                                     CASE WHEN p_result_file_id IS NULL THEN 'missing_result' END),
           error_message  = left(p_error_message, 2000),
           usage          = p_usage,
           attempts       = COALESCE(p_attempts, 0),
           finished_at    = now()
     WHERE id = p_job_id AND status = 'processing'
    RETURNING 1
  )
  SELECT EXISTS (SELECT 1 FROM done);
$$;

-- fail_stale_jobs: safety net for jobs stuck in 'processing' (e.g. n8n timeout).
-- Run from a scheduled n8n workflow; returns chats to notify. Minimum age 5 minutes.
CREATE OR REPLACE FUNCTION tryon.fail_stale_jobs(p_older_than interval DEFAULT '10 minutes')
RETURNS TABLE (job_id bigint, chat_id bigint)
LANGUAGE sql SECURITY DEFINER SET search_path = tryon, pg_temp AS $$
  UPDATE tryon_jobs j
     SET status = 'failed', error_code = 'timeout', finished_at = now()
    FROM users u
   WHERE u.id = j.user_id
     AND j.status = 'processing'
     AND j.created_at < now() - GREATEST(p_older_than, interval '5 minutes')
  RETURNING j.id, u.chat_id;
$$;
