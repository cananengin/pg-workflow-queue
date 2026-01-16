# Backend Developer Assessment - Atom AI

**Time estimate:** 2-3 hours  

---

## Context

We're building a durable workflow system where PostgreSQL serves as both database and job queue. Workers poll for pending tasks, claim them with time-limited leases, and execute them. If a worker crashes, expired leases allow other workers to reclaim and retry the work.

Your task is to implement a simplified version of this pattern.

---

## The Schema

See [`schema.sql`](./schema.sql) for the complete schema. The key tables are:

- **`jobs`** — Parent workflow instances with status tracking
- **`job_steps`** — Individual tasks within a job, with lease-based claiming

Key concepts:
- `locked_by` — The worker ID currently holding the lease
- `lease_expires_at` — When the lease expires (other workers can reclaim after this)
- `attempt` — How many times this step has been claimed
- `max_attempts` — Maximum claim attempts before permanent failure

---

## Your Tasks

### Task 1: PostgreSQL RPC — `claim_next_step`

Write a PostgreSQL function that claims the next available step for processing.

**Requirements:**

1. Find the oldest claimable step:
   - Status is `'pending'`, OR
   - Status is `'running'` but `lease_expires_at < NOW()` (expired lease)
2. Only claim steps where `attempt < max_attempts`
3. Only claim steps belonging to jobs with `status = 'running'`
4. Prevent concurrent workers from claiming the same step (no double-claiming)
5. Update the claimed step:
   - Set `status = 'running'`
   - Set `locked_by = p_worker_id`
   - Set `lease_expires_at = NOW() + p_lease_duration`
   - Increment `attempt`
6. Return the claimed step, or empty result if nothing available

**Function signature:**

```sql
CREATE OR REPLACE FUNCTION claim_next_step(
  p_worker_id TEXT,
  p_lease_duration INTERVAL DEFAULT '5 minutes'
)
RETURNS SETOF job_steps
LANGUAGE plpgsql
AS $$
  -- Your implementation here
$$;
```

---

### Task 2: PostgreSQL RPC — `complete_step`

Write a PostgreSQL function that marks a step as successfully completed.

**Requirements:**

1. Mark the step as `'completed'` with the provided output
2. Only succeed if:
   - Step status is currently `'running'`
   - `locked_by` matches the provided worker ID
3. Clear `locked_by` and `lease_expires_at`
4. Return the updated step, or empty result if validation failed

**Function signature:**

```sql
CREATE OR REPLACE FUNCTION complete_step(
  p_step_id UUID,
  p_worker_id TEXT,
  p_output JSONB
)
RETURNS SETOF job_steps
LANGUAGE plpgsql
AS $$
  -- Your implementation here
$$;
```

---

### Task 3: TypeScript Worker Loop

Write a TypeScript worker that polls for and processes steps.

**Requirements:**

1. Generate a unique worker ID on startup
2. Poll `claim_next_step` in a loop
3. Use exponential backoff when no work is available:
   - Start at 1 second
   - Double each time (with some jitter)
   - Cap at 30 seconds
   - Reset to 1 second when work is found
4. When a step is claimed:
   - Simulate work by waiting 2 seconds
   - Call `complete_step` with a simple output
5. Handle graceful shutdown on `SIGTERM`:
   - Stop claiming new work immediately
   - Finish processing current step (if any)
   - Exit cleanly

**Starter code:**

```typescript
import { createClient } from '@supabase/supabase-js';

const supabase = createClient(
  process.env.SUPABASE_URL!,
  process.env.SUPABASE_SERVICE_ROLE_KEY!
);

// Your implementation here
```

---

## Deliverables

Place your solutions in the following files:

| File | Contents |
|------|----------|
| `solution/claim_next_step.sql` | Task 1 implementation |
| `solution/complete_step.sql` | Task 2 implementation |
| `solution/worker.ts` | Task 3 implementation |
| `solution/SOLUTION.md` | Your explanation (see below) |

---

## Solution Write-Up (Required)

In `solution/SOLUTION.md`, explain:

1. **Your approach** — How does your `claim_next_step` prevent double-claiming? Why did you structure it this way?

2. **Assumptions** — What did you assume about the environment, error handling, or edge cases?

3. **Tradeoffs** — What would you do differently with more time? What corners did you cut?

4. **Edge cases considered** — Which edge cases did you handle? Which did you intentionally skip?

**We review this write-up as carefully as the code.** Submitting code with no explanation is a red flag.

---

## Evaluation Criteria

| Criteria | What we're looking for |
|----------|------------------------|
| **Correctness** | Handles concurrency properly, prevents double-claims, respects lease ownership |
| **Edge cases** | Expired leases, max attempts reached, job status checks |
| **Code clarity** | Readable structure, appropriate naming, helpful comments where needed |
| **Production thinking** | Error handling, logging considerations, shutdown safety |
| **Communication** | Clear explanation of approach and tradeoffs in SOLUTION.md |

---

## AI Usage

You may use AI tools (Copilot, Claude, ChatGPT, etc.). This reflects how we actually work.

However:
- You must be able to explain and modify every line in the follow-up interview
- The SOLUTION.md should be in your own voice — we're evaluating your judgment, not your ability to prompt
- Submitting AI output you don't understand will become obvious in the live pairing session

---

## Local Setup & Testing

This section explains how to run and test the solution locally using Supabase.

### Prerequisites

- Node.js 18+
- A Supabase project (free tier is sufficient)

---

### 1. Create a Supabase Project

1. Go to https://supabase.com
2. Create a new project
3. Wait for the database to be ready

---

### 2. Configure Environment Variables

Create a `.env` file in the project root:

```env
SUPABASE_URL=https://<your-project-ref>.supabase.co
SUPABASE_SERVICE_ROLE_KEY=<your-service-role-key>
```

You can find these values in your Supabase project settings under **API**:
- **Project URL** → use as `SUPABASE_URL`
- **service_role key** (secret) → use as `SUPABASE_SERVICE_ROLE_KEY`

---

### 3. Initialize Database Schema

In the Supabase Dashboard, open **SQL Editor** and run the following scripts in order:

1. **`schema.sql`** - Creates tables and test data
2. **`solution/claim_next_step.sql`** - Creates the claim function
3. **`solution/complete_step.sql`** - Creates the complete function

**Note:** If `gen_random_uuid()` is not available, enable the extension first:

```sql
CREATE EXTENSION IF NOT EXISTS pgcrypto;
```

---

### 4. Run the Worker

Install dependencies:

```bash
npm install
```

Start the worker:

```bash
npm start
```

**Expected output:**

```
Worker <uuid> starting...
Claimed step <id> (job <id>, seq <n>)
Completed step <id> successfully
No work available. Backing off for <ms>ms...
```

---

### 5. Verify Results

You can verify completed steps using the Supabase SQL Editor:

```sql
SELECT job_id, seq, status, attempt, locked_by, output
FROM job_steps
ORDER BY job_id, seq;
```

All eligible steps should eventually reach the `completed` state.

---

### Notes

- Multiple workers can be started simultaneously to verify concurrency safety
- If a worker crashes mid-step, the lease mechanism allows safe reclaiming after expiration
- Graceful shutdown is supported via `SIGTERM` (Ctrl+C)

---

## Submission

1. Create a public GitHub repository with your solution
2. Ensure all files are in place (see Deliverables above)
3. Email `hello@atom.new` to confirm submission


