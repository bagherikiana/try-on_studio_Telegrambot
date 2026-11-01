-- 009_one_stale_job_rule: one definition of "stuck job" instead of two.
-- fail_stale_jobs gets an optional user filter and a 5-minute default (was 10);
-- start_job calls it for the current user instead of repeating the UPDATE.
-- Also computes the timezone once in start_job.

DROP FUNCTION IF EXISTS tryon.fail_stale_jobs(interval);

-- Fails jobs stuck in 'processing' longer than p_older_than (never less than 5 minutes).
-- p_user_id NULL = all users (manual/admin sweep); set = only that user (used by start_job).
-- Returns the chats to notify.
CREATE FUNCTION tryon.fail_stale_jobs(
  p_older_than interval DEFAULT '5 minutes',
  p_user_id    bigint   DEFAULT NULL
) RETURNS TABLE (job_id bigint, chat_id bigint)
LANGUAGE sql SECURITY DEFINER SET search_path = tryon, pg_temp AS $$
  UPDATE tryon_jobs j
     SET status = 'failed', error_code = 'timeout', finished_at = now()
    FROM users u
   WHERE u.id = j.user_id
     AND j.status = 'processing'
     AND j.created_at < now() - GREATEST(p_older_than, interval '5 minutes')
     AND (p_user_id IS NULL OR j.user_id = p_user_id)
  RETURNING j.id, u.chat_id;
$$;

GRANT EXECUTE ON FUNCTION tryon.fail_stale_jobs(interval, bigint) TO n8n_app;

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
  v_tz        text;
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

  -- Self-healing: free this user from jobs stuck by a crashed workflow.
  PERFORM fail_stale_jobs(interval '5 minutes', p_user_id);

  -- Missing settings fall back to safe values (limit 0 = no try-ons).
  SELECT jsonb_object_agg(s.key, s.value) INTO cfg FROM settings s;
  v_model     := cfg->>'ai_model';
  v_prompt    := COALESCE(cfg->>'ai_prompt_version', 'v1');
  v_limit     := COALESCE(u.user_limit, (cfg->>'daily_limit')::integer, 0);
  v_tz        := COALESCE(cfg->>'timezone', 'UTC');
  v_day_start := date_trunc('day', now() AT TIME ZONE v_tz) AT TIME ZONE v_tz;

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
