// Replay and resolve as the console asks for them, shared by the jobs list and a job's detail. The server decides
// what may be done (JobActions); this asks first where a person must confirm, and says what happened
import LightningConfirm from 'lightning/confirm';
import replay from '@salesforce/apex/ConsoleJobs.replay';
import resolve from '@salesforce/apex/ConsoleJobs.resolve';
import ReplayrResolveModal from 'c/replayrResolveModal';

// The statuses JobActions.resolve takes
const RESOLVABLE = ['Outcome_Unknown', 'Dead'];

/**
 * @param {object} job a ConsoleJobs.Row
 * @returns {boolean} whether the job waits for a person to say how it ended
 */
export function isResolvable(job) {
    return RESOLVABLE.includes(job?.status);
}

/**
 * Replays jobs, first asking when any of them isn't Retry-safe.
 * @param {object[]} jobs ConsoleJobs.Row values
 * @returns {Promise<{variant: string, message: string}|undefined>} what happened, or undefined if the person said no
 */
export async function replayJobs(jobs) {
    const risky = jobs.filter((job) => job.replayable && !job.retrySafe).length;
    let confirmed = false;
    if (risky > 0) {
        const one = jobs.length === 1;
        confirmed = await LightningConfirm.open({
            label: one ? 'Replay a job that may send twice?' : 'Replay jobs that may send twice?',
            message:
                `${one ? 'This job is' : `${risky} of the selected jobs ${risky === 1 ? 'is' : 'are'}`} not Retry-safe: replaying may send the call twice, for example creating a second order or charge.` +
                (one && jobs[0].status === 'Outcome_Unknown' ? ' Its first call may already have worked: check with the other system, or resolve it instead.' : ''),
            theme: 'warning'
        });
        if (!confirmed) {
            return undefined;
        }
    }
    const jobIds = jobs.map((job) => job.id);
    return run(() => replay({ jobIds, duplicateRiskConfirmed: confirmed }), 'replayed');
}

/**
 * Resolves jobs with the outcome and note the person gives.
 * @param {object[]} jobs ConsoleJobs.Row values
 * @returns {Promise<{variant: string, message: string}|undefined>} what happened, or undefined if cancelled
 */
export async function resolveJobs(jobs) {
    const answer = await ReplayrResolveModal.open({ size: 'small', label: 'Resolve jobs', count: jobs.length });
    if (!answer) {
        return undefined;
    }
    const jobIds = jobs.map((job) => job.id);
    return run(() => resolve({ jobIds, outcome: answer.outcome, note: answer.note }), 'resolved');
}

async function run(call, verb) {
    try {
        const results = await call();
        const notDone = results.filter((result) => !result.done);
        const done = results.length - notDone.length;
        const summary = `${done} ${done === 1 ? 'job' : 'jobs'} ${verb}.`;
        return notDone.length ? { variant: 'warning', message: `${summary} ${notDone.length} not: ${reasons(notDone)}` } : { variant: 'success', message: summary };
    } catch (e) {
        return { variant: 'error', message: e?.body?.message ?? "Replayr couldn't do that. Nothing was changed." };
    }
}

// Each distinct reason once, so five jobs refused for two reasons show both
function reasons(notDone) {
    return [...new Set(notDone.map((result) => result.message))].join(' ');
}
