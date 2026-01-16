-- ============================================================================
-- TASK 2: complete_step
-- ============================================================================
--
-- Marks a step as successfully completed.
--
-- Requirements:
--   1. Mark the step as 'completed' with the provided output
--   2. Only succeed if status='running' AND locked_by matches worker
--   3. Clear locked_by and lease_expires_at
--   4. Return the updated step (or empty if validation failed)
--
-- ============================================================================

CREATE OR REPLACE FUNCTION complete_step(
  p_step_id UUID,
  p_worker_id TEXT,
  p_output JSONB
)
RETURNS SETOF job_steps
LANGUAGE plpgsql
AS $$
BEGIN
  -- Mark step as completed, but only if validation passes
  -- The WHERE clause ensures we only update if:
  --   - status is 'running' (step is currently being processed)
  --   - locked_by matches the worker (this worker owns the lease)
  --   - lease_expires_at exists and is still valid (lease hasn't expired)
  -- If validation fails, no rows are updated and empty result is returned
  RETURN QUERY
  UPDATE job_steps js
  SET
    status = 'completed',
    output = p_output,
    locked_by = NULL,
    lease_expires_at = NULL
  WHERE js.id = p_step_id
    AND js.status = 'running'
    AND js.locked_by = p_worker_id
    AND js.lease_expires_at IS NOT NULL
    AND js.lease_expires_at > NOW()
  RETURNING js.*;
END;
$$;
