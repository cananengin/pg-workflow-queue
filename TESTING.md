# Tests

This file contains simple SQL snippets to manually verify the RPC functions using the Supabase SQL Editor.

> **Notes:**
> - `claim_next_step` returns an empty result when no steps are claimable.
> - `complete_step` only succeeds when the caller owns the lease and the lease is still valid.

---

## Setup (One-time)

1. Run `schema.sql` in Supabase SQL Editor to create tables and test data
2. Run `solution/claim_next_step.sql` to create the claim function
3. Run `solution/complete_step.sql` to create the complete function

Verify setup:
```sql
SELECT COUNT(*) FROM jobs; -- Should return 3
SELECT COUNT(*) FROM job_steps; -- Should return 8
```

---

## 1) Test `claim_next_step`

```sql
-- Returns the oldest claimable step (pending OR running with expired lease)
SELECT * FROM claim_next_step('test-worker-1', '5 minutes');
```

**Expected:**
- Returns exactly 1 row when work is available
- Returns no rows when the queue is empty or nothing is claimable

---

## 2) Test `complete_step`

```sql
-- Claims a step and immediately completes it (lease must still be valid)
WITH claimed AS (
  SELECT * FROM claim_next_step('test-worker-1', '5 minutes') LIMIT 1
)
SELECT *
FROM complete_step(
  (SELECT id FROM claimed),
  'test-worker-1',
  '{"test":"output"}'::jsonb
);
```

**Expected:**
- Returns 1 row with `status = 'completed'`
- `locked_by` and `lease_expires_at` should be NULL

---

## 3) Test validation failure: wrong worker cannot complete

```sql
-- Wrong worker should NOT be able to complete the step
WITH claimed AS (
  SELECT * FROM claim_next_step('test-worker-1', '5 minutes') LIMIT 1
)
SELECT *
FROM complete_step(
  (SELECT id FROM claimed),
  'other-worker',
  '{"test":"should-fail"}'::jsonb
);
```

**Expected:**
- No rows returned (validation should fail)

---

## 4) Test validation failure: expired lease cannot complete

Force a short lease, wait for it to expire, then try to complete (should fail).

**Step A:** Claim with a very short lease and capture the id:

```sql
WITH claimed AS (
  SELECT * FROM claim_next_step('test-worker-1', '1 second') LIMIT 1
)
SELECT id FROM claimed;
```

**Then wait ~2 seconds** and run:

**Step B:** Attempt to complete after lease expiry (should fail):

```sql
-- Replace <STEP_ID> with the claimed step id from Step A
SELECT *
FROM complete_step(
  '<STEP_ID>'::uuid,
  'test-worker-1',
  '{"test":"lease-expired"}'::jsonb
);
```

**Expected:**
- No rows returned (lease expired)

---

## 5) Test expired lease reclaim (crash recovery)

This test simulates a worker crash by:
1. Claiming a step with a very short lease
2. Waiting for the lease to expire
3. Claiming again with a different worker

**Step A:** Claim with short lease:

```sql
WITH claimed AS (
  SELECT * FROM claim_next_step('crash-worker', '1 second') LIMIT 1
)
SELECT id, status, locked_by, lease_expires_at, attempt FROM claimed;
```

**Wait ~2 seconds**, then run:

**Step B:** Reclaim with a different worker after the lease expires:

```sql
SELECT id, status, locked_by, lease_expires_at, attempt
FROM claim_next_step('reclaimer-worker', '5 minutes');
```

**Expected:**
The reclaimed row should show:
- `locked_by = 'reclaimer-worker'`
- `status = 'running'`
- `attempt` increased by 1 compared to Step A

---

## 6) Verify current table state

```sql
SELECT job_id, seq, status, attempt, max_attempts, locked_by, lease_expires_at, output
FROM job_steps
ORDER BY job_id, seq;
```

**Expected:**
- Completed steps: `status='completed'`, `locked_by NULL`, `lease_expires_at NULL`
- Cancelled job steps remain unclaimed
- Steps with `attempt >= max_attempts` are not claimable
