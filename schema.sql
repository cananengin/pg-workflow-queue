-- ============================================================================
-- ATOM BACKEND ASSESSMENT — DATABASE SCHEMA
-- ============================================================================
-- 
-- This schema represents a simplified version of our workflow system.
-- You'll implement functions that operate on these tables.
--
-- To set up locally:
--   1. Create a Supabase project (free tier is fine)
--   2. Run this script in the SQL Editor
--   3. Use the service_role key for your worker
--
-- ============================================================================

-- Jobs table: parent workflow instances
CREATE TABLE jobs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  status TEXT NOT NULL DEFAULT 'running',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Enforce valid status values
ALTER TABLE jobs ADD CONSTRAINT jobs_status_check
  CHECK (status IN ('running', 'completed', 'failed', 'cancelled'));

-- Index for finding active jobs
CREATE INDEX idx_jobs_status ON jobs (status);


-- Job steps table: individual tasks within a job
CREATE TABLE job_steps (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  job_id UUID NOT NULL REFERENCES jobs(id) ON DELETE CASCADE,
  seq INT NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  input JSONB,
  output JSONB,
  error JSONB,
  locked_by TEXT,                -- Worker ID holding the lease
  lease_expires_at TIMESTAMPTZ,  -- When the lease expires
  attempt INT NOT NULL DEFAULT 0,
  max_attempts INT NOT NULL DEFAULT 3,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  
  UNIQUE (job_id, seq)
);

-- Enforce valid status values
ALTER TABLE job_steps ADD CONSTRAINT job_steps_status_check
  CHECK (status IN ('pending', 'running', 'completed', 'failed', 'cancelled'));

-- Enforce attempt bounds
ALTER TABLE job_steps ADD CONSTRAINT job_steps_attempt_check
  CHECK (attempt >= 0 AND max_attempts >= 1);

-- Index for finding pending steps (most common claim path)
CREATE INDEX idx_job_steps_pending 
  ON job_steps (status, created_at) 
  WHERE status = 'pending';

-- Index for finding expired leases (crash recovery path)
CREATE INDEX idx_job_steps_expired 
  ON job_steps (status, lease_expires_at) 
  WHERE status = 'running';

-- Index for looking up steps by job
CREATE INDEX idx_job_steps_job_id ON job_steps (job_id);


-- ============================================================================
-- TEST DATA
-- ============================================================================
-- 
-- Run this to create some test data for local development.
-- Feel free to modify or extend for your testing.
--

-- Create a few test jobs
INSERT INTO jobs (id, status) VALUES
  ('11111111-1111-1111-1111-111111111111', 'running'),
  ('22222222-2222-2222-2222-222222222222', 'running'),
  ('33333333-3333-3333-3333-333333333333', 'cancelled');

-- Create steps for the first job
INSERT INTO job_steps (job_id, seq, status, input) VALUES
  ('11111111-1111-1111-1111-111111111111', 1, 'pending', '{"task": "step-1"}'),
  ('11111111-1111-1111-1111-111111111111', 2, 'pending', '{"task": "step-2"}'),
  ('11111111-1111-1111-1111-111111111111', 3, 'pending', '{"task": "step-3"}');

-- Create steps for the second job
INSERT INTO job_steps (job_id, seq, status, input) VALUES
  ('22222222-2222-2222-2222-222222222222', 1, 'pending', '{"task": "other-step-1"}'),
  ('22222222-2222-2222-2222-222222222222', 2, 'pending', '{"task": "other-step-2"}');

-- Create a step for the cancelled job (should NOT be claimable)
INSERT INTO job_steps (job_id, seq, status, input) VALUES
  ('33333333-3333-3333-3333-333333333333', 1, 'pending', '{"task": "cancelled-job-step"}');

-- Create a step with an expired lease (simulates crashed worker)
INSERT INTO job_steps (job_id, seq, status, input, locked_by, lease_expires_at, attempt) VALUES
  ('11111111-1111-1111-1111-111111111111', 4, 'running', '{"task": "crashed-step"}', 
   'dead-worker-123', NOW() - INTERVAL '10 minutes', 1);

-- Create a step that has exhausted all attempts (should NOT be claimable)
INSERT INTO job_steps (job_id, seq, status, input, locked_by, lease_expires_at, attempt, max_attempts) VALUES
  ('22222222-2222-2222-2222-222222222222', 3, 'running', '{"task": "exhausted-step"}',
   'dead-worker-456', NOW() - INTERVAL '10 minutes', 3, 3);


-- ============================================================================
-- VERIFICATION QUERIES
-- ============================================================================
--
-- Use these to verify your implementation works correctly.
--

-- Should return 5 claimable steps:
-- - 3 pending from job 1
-- - 2 pending from job 2
-- - 1 expired lease from job 1 (the crashed step)
-- Should NOT include:
-- - Step from cancelled job
-- - Exhausted step (attempt >= max_attempts)

/*
SELECT 
  js.id,
  js.job_id,
  js.seq,
  js.status,
  js.attempt,
  js.max_attempts,
  js.locked_by,
  js.lease_expires_at,
  j.status AS job_status
FROM job_steps js
JOIN jobs j ON j.id = js.job_id
WHERE j.status = 'running'
  AND js.attempt < js.max_attempts
  AND (
    js.status = 'pending'
    OR (js.status = 'running' AND js.lease_expires_at < NOW())
  )
ORDER BY js.created_at;
*/
