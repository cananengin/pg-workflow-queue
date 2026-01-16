-- ============================================================================
-- TASK 1: claim_next_step
-- ============================================================================
--
-- Claims the next available step for processing.
--
-- Requirements:
--   1. Find the oldest claimable step (pending OR running with expired lease)
--   2. Only claim steps where attempt < max_attempts
--   3. Only claim steps belonging to jobs with status = 'running'
--   4. Prevent concurrent workers from claiming the same step
--   5. Update: status='running', locked_by, lease_expires_at, increment attempt
--   6. Return the claimed step (or empty if nothing available)
--
-- ============================================================================

CREATE OR REPLACE FUNCTION claim_next_step(
  p_worker_id TEXT,
  p_lease_duration INTERVAL DEFAULT '5 minutes'
)
RETURNS SETOF job_steps
LANGUAGE plpgsql
AS $$
DECLARE
  v_step_id UUID;
BEGIN
  -- Find and lock the next claimable step atomically.
  -- FOR UPDATE SKIP LOCKED prevents concurrent workers from claiming the same row.
  SELECT js.id
  INTO v_step_id
  FROM job_steps js
  JOIN jobs j ON j.id = js.job_id
  WHERE j.status = 'running'
    AND js.attempt < js.max_attempts
    AND (
      js.status = 'pending'
      OR (
        js.status = 'running'
        AND js.lease_expires_at IS NOT NULL
        AND js.lease_expires_at < NOW()
      )
    )
  -- Deterministic ordering:
  -- 1) oldest created first
  -- 2) stable grouping by job
  -- 3) within a job, earlier seq first
  -- 4) final tiebreaker by id
  ORDER BY js.created_at ASC, js.job_id ASC, js.seq ASC, js.id ASC
  FOR UPDATE OF js SKIP LOCKED
  LIMIT 1;

  IF v_step_id IS NULL THEN
    RETURN; -- empty set
  END IF;

  -- Claim and return in one statement
  RETURN QUERY
  UPDATE job_steps
  SET status = 'running',
      locked_by = p_worker_id,
      lease_expires_at = NOW() + p_lease_duration,
      attempt = attempt + 1
  WHERE id = v_step_id
  RETURNING *;
END;
$$;
