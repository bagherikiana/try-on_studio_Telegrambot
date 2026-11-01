-- 010_stale_after_10_minutes: a try-on can legitimately take ~6.5 minutes
-- (180 s provider timeout + one retry + downloads). Healing at 5 minutes could fail
-- a job that is still running, so "stuck" now means older than 10 minutes.
-- Same signatures, so grants stay in place.

CREATE OR REPLACE FUNCTION tryon.fail_stale_jobs(
  p_older_than interval DEFAULT '10 minutes',
  p_user_id    bigint   DEFAULT NULL
) RETURNS TABLE (job_id bigint, chat_id bigint)
LANGUAGE sql SECURITY DEFINER SET search_path = tryon, pg_temp AS $$
  UPDATE tryon_jobs j
     SET status = 'failed', error_code = 'timeout', finished_at = now()
    FROM users u
   WHERE u.id = j.user_id
     AND j.status = 'processing'
     AND j.created_at < now() - GREATEST(p_older_than, interval '10 minutes')
     AND (p_user_id IS NULL OR j.user_id = p_user_id)
  RETURNING j.id, u.chat_id;
$$;

-- start_job keeps calling fail_stale_jobs(interval '5 minutes', p_user_id) from 009;
-- the 10-minute floor above now applies to that call too, so start_job needs no change.
