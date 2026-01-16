# Solution Write-Up

## Your Approach

### claim_next_step (double-claim prevention)

`claim_next_step` prevents double-claiming by using PostgreSQL row-level locks via `FOR UPDATE SKIP LOCKED`.

1. **Row locking on selection**  
   The query selects exactly one "oldest claimable" `job_steps` row and applies `FOR UPDATE OF js`, which acquires a row-level lock on that step.

2. **Skip locked rows (no worker blocking)**  
   With `SKIP LOCKED`, if another worker has already locked a row, PostgreSQL skips it instead of blocking. This allows multiple workers to poll concurrently without stepping on each other.

3. **Safe two-step pattern under contention**  
   This implementation uses a two-phase approach (SELECT then UPDATE), but it remains safe because the SELECT uses row locking. A plain `SELECT` followed by `UPDATE` **without** `FOR UPDATE SKIP LOCKED` would be race-prone.

4. **Correctness + performance**  
   The pattern is a common best practice for DB-backed queues: workers compete on the same table, but locks ensure each step is claimed once while remaining non-blocking under load.

**Flow:**
- **Phase 1:** Select and lock the oldest claimable step with `SELECT ... FOR UPDATE SKIP LOCKED`.
- **Phase 2:** Claim it with `UPDATE ... RETURNING *` to set status/lease/attempt and return the row.

### complete_step (strict lease ownership)

`complete_step` is implemented as a single `UPDATE ... WHERE ... RETURNING` and only succeeds if:
- the step is currently `running`,
- `locked_by` matches the worker,
- and the lease is still valid (`lease_expires_at > NOW()`).

If any of those validations fail (e.g., lease expired and another worker reclaimed it), the UPDATE affects 0 rows and returns an empty result.

---

## Assumptions

### Environment Assumptions
1. **PostgreSQL Version**: PostgreSQL 9.5+ (required for `SKIP LOCKED`)
2. **Supabase Compatibility**: Supabase RPC can call standard PostgreSQL functions
3. **Node.js Runtime**: Node.js 18+ for `crypto.randomUUID()`

### Operational Assumptions
1. **Database time is the source of truth**: Lease comparisons use `NOW()` from PostgreSQL, not worker clocks
2. **Jobs are managed externally**: This solution only checks `jobs.status = 'running'` at claim time
3. **No step dependencies**: Steps are claimable based on status/lease/attempt/job status; no seq-based gating was required by the prompt

---

## Tradeoffs

### What I would do with more time
1. **Failure path RPCs and cleanup**
   - Add `fail_step` to record `error` and mark steps as `failed`
   - Add logic to mark steps with `attempt >= max_attempts` as `failed` (and optionally fail the parent job)

2. **Observability**
   - Structured logs and basic metrics (claimed/completed counts, processing duration, error rate)
   - Optional health endpoint / liveness indicator for orchestration

3. **Lease management**
   - Heartbeat/lease extension for long-running work
   - Step-type based lease durations

4. **Testing**
   - Automated concurrency tests (multiple workers, no double-claim)
   - Integration tests verifying expired-lease reclaim and completion validation

### Corners cut intentionally
- No lease heartbeat/extension (steps are assumed to finish within the lease)
- No explicit "dead letter queue" table
- No job cancellation propagation to already-running steps

---

## Edge Cases

### Handled
1. **Concurrent workers**: `FOR UPDATE SKIP LOCKED` ensures each step is claimed once without blocking
2. **Expired leases**: `running` steps with `lease_expires_at < NOW()` are reclaimable
3. **Attempt exhaustion**: steps with `attempt >= max_attempts` are not claimable
4. **Job status filter**: only steps from jobs with `status = 'running'` are claimable
5. **Wrong worker completion**: `complete_step` requires `locked_by = p_worker_id`
6. **Expired lease completion**: `complete_step` requires `lease_expires_at > NOW()`
7. **No work available**: exponential backoff with jitter to avoid hammering the database
8. **Graceful shutdown intent**: worker stops claiming new work when SIGTERM is received and finishes the current step

### Intentionally skipped (and why)
1. **Step dependencies / seq gating**  
   The schema contains `seq` but the prompt did not require enforcing "seq order". Adding dependencies would change the claim predicate and require additional rules.

2. **Marking exhausted steps as failed**  
   The prompt only required excluding exhausted steps from claiming. In production I would add a cleanup job/RPC to mark them `failed` and alert.

3. **Job cancellation during processing**  
   The worker does not re-check job status while processing a step. This is a product decision; some systems allow in-flight work to finish.

4. **Lease heartbeats**  
   Keeping leases alive for long-running steps adds complexity and is unnecessary for this simplified assessment.

---

## Testing

I planned verification around the provided schema + test data:

1. **Load schema and seed data**
   - Run `schema.sql` in Supabase SQL editor
   - Run `claim_next_step.sql` and `complete_step.sql`

2. **Functional checks**
   - Call `claim_next_step(workerA)` repeatedly and verify it returns the oldest claimable steps
   - Confirm cancelled job steps are never returned
   - Confirm steps with `attempt >= max_attempts` are never returned

3. **Lease behavior**
   - Verify a `running` step with expired lease is reclaimed by `claim_next_step`
   - Verify `complete_step` returns empty if the lease is expired or the worker doesn't match

4. **Concurrency check**
   - Run two workers in parallel and confirm each step is claimed exactly once (no duplicates), and that workers do not block each other.

---

## Questions or Concerns

1. **Step ordering**: Should steps be strictly sequential per job (`seq`), or is parallel processing acceptable?
2. **Failure policy**: When a step exceeds max attempts, should the step be marked `failed` automatically and should the parent job fail?
3. **Lease tuning**: Is the default 5-minute lease aligned with expected step duration, or should it be step-type specific?

Overall, the solution implements a durable, DB-backed leasing pattern with safe concurrent claiming, strict ownership checks on completion, and worker-side backoff/shutdown behavior appropriate for a simplified assessment.
