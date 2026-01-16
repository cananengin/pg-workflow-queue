// ============================================================================
// TASK 3: Worker Loop
// ============================================================================
//
// A polling worker that claims and processes job steps.
//
// Requirements:
//   1. Generate a unique worker ID on startup
//   2. Poll claim_next_step in a loop
//   3. Exponential backoff when no work (1s -> 30s, reset on work found)
//   4. Simulate work (2 second wait), then call complete_step
//   5. Graceful shutdown on SIGTERM (finish current step, then exit)
//
// ============================================================================

import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';
import * as crypto from 'crypto';

const supabase = createClient(
  process.env.SUPABASE_URL!,
  process.env.SUPABASE_SERVICE_ROLE_KEY!
);

const workerId = crypto.randomUUID();
console.log(`Worker ${workerId} starting...`);

let shouldShutdown = false;
let currentStep: any = null;
let backoffDelay = 1000;

process.on('SIGTERM', () => {
  console.log(`SIGTERM received. Worker ${workerId} shutting down gracefully...`);
  shouldShutdown = true;
  if (currentStep) {
    console.log(`Will finish current step ${currentStep.id} before exiting...`);
  }
});

const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));

const addJitter = (delay: number) => {
  const jitter = delay * 0.2 * (Math.random() * 2 - 1);
  return Math.max(100, Math.floor(delay + jitter));
};

async function workerLoop(): Promise<void> {
  while (true) {
    // Stop claiming immediately
    if (shouldShutdown && !currentStep) {
      console.log('Shutdown requested and no current step. Exiting cleanly.');
      return;
    }

    try {
      // If shutdown was requested, do not claim new work
      if (shouldShutdown) {
        // If we are here, currentStep exists and will be finished by the existing flow
        await sleep(50);
        continue;
      }

      const { data: step, error } = await supabase.rpc('claim_next_step', {
        p_worker_id: workerId,
        p_lease_duration: '5 minutes',
      });

      if (error) {
        console.error(`Error claiming step:`, error);
        const delayWithJitter = addJitter(backoffDelay);
        await sleep(delayWithJitter);
        backoffDelay = Math.min(backoffDelay * 2, 30000);
        continue;
      }

      if (!step || step.length === 0) {
        const delayWithJitter = addJitter(backoffDelay);
        console.log(`No work available. Backing off for ${delayWithJitter}ms...`);
        await sleep(delayWithJitter);
        backoffDelay = Math.min(backoffDelay * 2, 30000);
        continue;
      }

      const claimedStep = step[0];
      currentStep = claimedStep;
      backoffDelay = 1000;

      console.log(`Claimed step ${claimedStep.id} (job ${claimedStep.job_id}, seq ${claimedStep.seq})`);

      await sleep(2000);

      const { data: completedStep, error: completeError } = await supabase.rpc('complete_step', {
        p_step_id: claimedStep.id,
        p_worker_id: workerId,
        p_output: { completed_at: new Date().toISOString(), worker: workerId },
      });

      if (completeError) {
        console.error(`Error completing step ${claimedStep.id}:`, completeError);
      } else if (completedStep && completedStep.length > 0) {
        console.log(`Completed step ${claimedStep.id} successfully`);
      } else {
        console.warn(`Failed to complete step ${claimedStep.id} (validation failed or lease expired)`);
      }

      currentStep = null;

      // If shutdown came during processing, loop will exit at the top
    } catch (err) {
      console.error('Unexpected error in worker loop:', err);
      const delayWithJitter = addJitter(backoffDelay);
      await sleep(delayWithJitter);
      backoffDelay = Math.min(backoffDelay * 2, 30000);
    }
  }
}

workerLoop()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error('Fatal error in worker:', err);
    process.exit(1);
  });
