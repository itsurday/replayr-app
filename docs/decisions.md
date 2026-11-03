# Architecture decisions

This file has two parts.

1. **Platform spikes (P0.x, P4.x).** Before writing package code I ran a set of throwaway experiments against a real org to settle the questions the design depended on. Each spike records the question, how it was tested, what happened, and what it changed. The spike code is kept in `archive/` and never deployed.
2. **Architecture Decision Records (ADR-001 onward).** One entry per decision: the context, the decision, and its consequences. Many of these decisions are *permanent* once a managed package version is promoted (field names, picklist values, global signatures), so the ADRs say so where it matters.

Unless noted, evidence comes from an Enterprise scratch org on API 68.0 (Winter '27). Scratch orgs don't always behave like production; anything that may be scratch-only is flagged.

---

## Part 1: platform spikes

### P0.1 Delayed Queueables and scheduled Apex timing

**Question.** What is the longest delay a delayed Queueable accepts, and how often can a single scheduled job fire?

**Method.** `System.enqueueJob(job, delay)` with delays of 0, 1, 10 and 11 minutes, and `System.schedule` with four cron expressions. Each job logged its actual start time.

**Result.**

- Delays of 0, 1 and 10 minutes ran after roughly 0, 60 and 600 seconds. A delay of 11 is rejected: `InvalidParameterValueException: Delay must be less than or equal to 10 minutes`.
- Cron seconds and minutes must be single integers. `0 * * * * ?`, `0 0/5 * * * ?` and `0 0,30 * * * ?` are all rejected; `0 0 * * * ?` is accepted. One scheduled job can therefore fire at most hourly.

**Impact.** Backoff runs at two speeds: a delayed Queueable for waits up to 10 minutes, and one hourly scheduled poller for anything longer.

### P0.2 Dispatcher, worker and claiming

**Questions.** (a) How many Queueables can an async dispatcher start? (b) Can a worker call out after its claim was committed in another transaction? (c) Can two overlapping claimers take the same job?

**Result (a): a Queueable can enqueue only one Queueable.** Two `System.enqueueJob` calls failed with `Too many queueable jobs added to the queue: 2` and rolled back the whole transaction. A *scheduled* job, by contrast, can enqueue up to 50 (P0.2c).

**Result (b): yes, provided the callout comes before any DML in the same transaction.** The negative control (DML, then callout) fails with `CalloutException: You have uncommitted work pending`.

**Result (c): no duplicate claims.** Two transactions started 26 ms apart, each running `SELECT ... WHERE Status__c = 'Queued' LIMIT 50 FOR UPDATE` and holding the locks for 6 seconds. The first claimed all 50 jobs. The second blocked for about 6.1 s and then returned **0 rows**: the `WHERE` clause is re-evaluated against committed data once the lock clears.

A follow-up with 80 queued jobs confirmed that a blocked claimer doesn't come back empty while work remains:

| Claim size | First claimer | Second claimer (after ~6.1 s wait) | Total |
| --- | --- | --- | --- |
| `LIMIT 1` | 1 job (seq 1) | 1 job (seq 2), the next free row | 2 claimed, 78 still queued |
| `LIMIT 50` | 50 jobs | the remaining 30 | 80, each claimed once |

Separately, six Queueables from two sessions ran with up to five executing at once, so independent chains do run in parallel.

**Impact.** "A dispatcher fans out to workers" doesn't work from a Queueable. I looked at four shapes: a single self-chaining worker, fan-out from synchronous entry points, N parallel self-chaining workers, and Batch Apex with scope 1 (which loses the Transaction Finalizer). The design uses **self-chaining workers that claim one job at a time with `FOR UPDATE`, call out first and write afterwards**. See ADR-004 for how many chains run.

### P0.2b Inner-class Schedulables never run

**Question.** Some one-time scheduled jobs fired (`TimesTriggered = 1`, AsyncApexJob `Completed`, no error) but wrote nothing. Why?

**Method.** A 2×2 matrix scheduled for the same minute with trace flags on: top-level vs inner class, crossed with a plain insert vs a logging helper.

**Result.** Top-level classes ran in both cases. Inner classes did **nothing**: no row and no debug log, yet AsyncApexJob reports `Completed` with no `ExtendedStatus`. This was consistent across six attempts. I've only seen it in an Enterprise scratch org on API 68.0, so it may be scratch- or release-specific.

**Impact.**

- **Rule: every Schedulable (poller, purge, any future roll-up) is a top-level class.** It's on the review checklist because the failure is silent.
- Health checks must look for evidence that a scheduled job did its work (the poller writes a heartbeat) rather than trust `Completed`.

### P0.2c Scheduled Apex fan-out

A top-level Schedulable sees `Limits.getLimitQueueableJobs() = 50` and can enqueue that many. So the hourly poller, running as the integration user, can start or restart chains directly. Within a chain each link still starts only one successor.

### P0.3 Finalizer after an uncatchable limit exception

**Question.** Does a Transaction Finalizer run after a `LimitException`, and what does it see?

**Method.** A worker attached a finalizer, made a real callout, inserted a row, recorded progress on the finalizer instance after each step, then spun until it hit the CPU limit.

**Result.**

- The finalizer **runs**: `UNHANDLED_EXCEPTION; System.LimitException: Apex CPU time limit exceeded`.
- It sees the finalizer instance's state **at the moment of the crash**, not at attach time: `callout returned HTTP 200; DML done`.
- The worker's own DML is rolled back.

**Impact.** This is the basis of the crash-recovery design. The worker writes the HTTP status and a bounded summary onto its finalizer right after the callout, so if the transaction dies afterwards the finalizer records the real outcome and the call is never resent. *Outcome unknown* is then reserved for a worker that dies **during** the callout, or one whose finalizer never runs (the watchdog's job). Anything held on the finalizer must stay small because of heap limits.

### P0.4 Run-as user per entry point

**Question.** Which user does each background entry point run as, and can the work be moved onto a dedicated integration user?

| Entry point | Runs as |
| --- | --- |
| Queueable enqueued by a user, and anything it chains | that user (inherited) |
| Record-triggered flow, Run Asynchronously path, invocable Apex | the user who saved the record |
| Platform-event trigger, default | **Automated Process** |
| Platform-event trigger with `PlatformEventSubscriberConfig` | **the configured user**, inherited by Queueables it enqueues |
| Scheduled Apex (top-level class) | whoever scheduled it |

Two practical findings:

- A new subscriber config takes effect **only after the trigger's subscription is suspended and resumed**. Deployed but not restarted, the trigger silently keeps running as Automated Process.
- Run-as is inherited down a Queueable chain, so whoever starts a chain decides the user for every job in it.

**Impact.** This gives the integration-user hand-off (ADR-003): entry points publish an event, and the event trigger runs as the integration user and starts the chains.

### P0.5 Identity edge cases

- **A deactivated owner's scheduled job fails visibly:** AsyncApexJob shows `Failed` with `Inactive User`, and Salesforce allows the deactivation without a warning. Scheduled jobs must be owned by the dedicated, always-active integration user, and health checks look for that failure.
- **Automated Process can be granted credential access** (permission set assignment succeeds and the callout returns 200). So it isn't a hard blocker, but a dedicated user still gives a clearer audit trail and one place to grant access.
- **A free Salesforce Integration licence user works as the integration user**, with one addition: callouts fail with `You don't have read permissions on the User External Credential object` until Read on `UserExternalCredential` is granted. That matters for small customers, who don't have to give up a paid seat.

### P0.6 Credential onboarding through ConnectApi

**Question.** Could Apex power a credential setup wizard?

| Step | Result |
| --- | --- |
| Create External and Named Credential | works, once `calloutOptions` is supplied |
| Store the secret in the **same** transaction | fails with an opaque internal error |
| Store the secret in a **later** transaction | works |
| Grant principal access (`SetupEntityAccess` insert) | works |
| Switch on "Enabled for Callouts" from Apex | **not possible**: `NamedCredentialInput` has no `calloutStatus` at API 68.0 |
| Read the secret back | no value, `encrypted = true` |

**Impact.** A wizard is possible but needs at least one manual Setup step, has to be split across transactions, and has to cope with half-finished setups. It also means secrets would pass through package code. ADR-023 decides against it for v1.

### P0.7 Professional Edition

Unpackaged Apex can't be deployed to a Professional scratch org (`Not available for deploy for this organization`), so none of the async machinery can be verified there before a package exists. The org had no Salesforce Integration licences, and its standard-volume platform event limit is a hundredfold lower (1,000 per hour vs 100,000). See ADR-002.

### P4.1 Platform-event hand-off mechanics

- Publishing an event needs Create on it, even from Apex, and the failure comes back in the `SaveResult` rather than as an exception. Create in turn requires Read.
- An event with no custom fields deploys and publishes, and publishing counts as one DML statement.
- A platform-event trigger enqueued 50 Queueables in one run.
- `AsyncOptions.DuplicateSignature` refuses a second job **only while the first is still queued**. While the first is processing, a second is accepted. So a signature stops a double start from the queue, not a parallel chain.
- The trigger's run-as user can only be set through the Metadata or Tooling API (`PlatformEventSubscriberConfig`). Setup can only display it and suspend or resume the subscription.

### P4.2 What package Apex can learn about a Named Credential

- `ConnectApi.NamedCredentials.getNamedCredential(name).calloutStatus` gives the callout switch, and `getExternalCredential` gives the principals. `SetupEntityAccess` then shows which permission sets grant each principal. SOQL can't read `ExternalCredential` or `UserExternalCredential`.
- All of it requires **View Setup and Configuration**, even for a Replayr Admin.
- In a subscriber org, `getNamedCredential` called from package code **doesn't see the subscriber's own unnamespaced credential**, even though callouts find it. SOQL on `NamedCredential` with `NamespacePrefix = NULL` does see it, but without the callout status or External Credentials.

---

## Part 2: architecture decision records

### ADR-001 Positioning: reliability first

**Context.** Plain "call an API without code" is crowded, and Salesforce gives a basic version away with Flow HTTP Callout. The closest AppExchange competitor offers generic fixed-interval retry with no duplicate protection ([market-check.md](market-check.md)).

**Decision.** Position Replayr as *"connect any API without code, and never lose or duplicate a call"*: every call logged, failed calls replayed safely, duplicates prevented. Lead with one painful use case (orders and payments), and treat integration monitoring as a v2 expansion.

**Consequences.** Reliability is harder to demo than a connector catalogue, so the console has to make it visible: the job log, the "needs a person" queue, and the replay confirmation that names the duplicate risk.

### ADR-002 Supported editions

**Decision.** v1 supports Enterprise, Unlimited, Performance and Developer. Professional is out of scope (P0.7) and gets revisited with an installed package after security review.

### ADR-003 All background work runs as one integration user

**Context.** Callouts need credential access, which should be granted to one non-human user, not to every person who saves a record. A chain inherits the user who starts it (P0.4).

**Decision.**

- Code that saves or re-queues jobs publishes a bare `Replayr_Work_Waiting__e` event carrying no data. Its trigger runs as the integration user, configured through `PlatformEventSubscriberConfig`, and starts the worker chain.
- The trigger only acts when it runs as an **active user holding the Replayr Integration User permission set** (directly or through a group). Running as Automated Process or anyone else, it records the user for the health panel and does nothing more. So jobs wait instead of failing for lack of credentials, and no call ever runs with wider access than Replayr's own.
- On its first successful run as the integration user, the trigger schedules the hourly poller, so the poller is owned by that user too.
- Replayr doesn't create the subscriber config itself, because that would need a Metadata API connection from the org to itself. The admin guide provides a small file to deploy, plus the suspend and resume step.

**Consequences.** Before setup, nothing is sent and nothing is lost. Anyone with Create on the event (every sender) can publish it through the API, but that only brings forward work that was already due, at most one chain at a time.

### ADR-004 Job engine: one org-wide worker chain

**Decision.**

- **One chain for the whole org for now.** The trigger and the poller start a chain only when no job has been claimed within the last 5 minutes (a link's work takes about two minutes at most). Every link that holds a job carries the same duplicate signature, which refuses a second start while a link is queued.
- Every claim locks its job with `FOR UPDATE` and never takes a `Processing` job, so a rare second chain is harmless.
- The delayed wake-up link for a due retry carries no signature. It can wait up to ten minutes and would otherwise block new work all that time.
- **Chain hand-over.** Scratch, Developer and Trial orgs end a Queueable chain after 5 links. When the next enqueue fails with an `AsyncException`, the link undoes its claim and publishes the work-waiting event, and a fresh chain picks up through the same guard. A `DuplicateMessageException` is not an `AsyncException` and just ends the chain. It is never published from inside a trigger, so the hand-off can't loop.

**Consequences.** Throughput is one call at a time per org, which is enough for the target customer. Per-provider concurrency can be added later without changing any permanent component.

### ADR-005 Endpoints have no sync/async "type"

**Decision.** Every call goes through a job and is logged. Whether to wait for the answer (test mode) or queue it (a record-triggered flow) is the caller's choice. A type field would force duplicate endpoints for one remote operation, and its picklist values would be permanent.

### ADR-006 Mapping storage, merge syntax and the `{!` rule

**Decision.**

- One `Mapping__c` per endpoint direction, holding its rules as JSON in a long text field. That keeps export and import simple, and the console provides the editor.
- Merge syntax `{{Field}}` and `{{Parent.Field}}`. Inside a JSON string a value is merged as escaped text (missing becomes empty); a bare merge field is merged as a JSON value (missing becomes `null`). Where the admin puts the quotes decides which.
- **Any `{!` is rejected in templates, in rules and in every merged value.** I tested this: with a Named Credential's "Allow Formulas in HTTP Body" on, the platform replaces `{!$Credential...}` in a body with the stored secret and sends it to the remote API. Customers control that switch, so the check is required. It runs when the body is built, not just when the mapping is saved, because Data Loader can write mappings directly, and a record's own data (an Account named `{!$Credential.X.ApiKey}`) is just as dangerous.

### ADR-007 Conditional values in mappings

**Decision.** `{{IF(test, then, else)}}` with tests `=`, `!=`, `ISBLANK()` and `NOT(ISBLANK())`, with no nesting. Text compares ignoring case, as formulas do. Numbers compare by value (`100 = 100.00`). Other values compare by their merged text form. Quoted text can't contain `'`, `{`, `}` or a backslash, and doubled quotes are reserved as the future escape.

**Consequences.** This syntax is permanent once released, so everything not supported today (AND/OR, nesting, `EXACT()`) is a parse error today. That lets them be added later without changing the meaning of existing mappings.

### ADR-008 Response writer

**Decision.**

- Rules format: `{"fields": {"Field__c": "json.path"}}`. Any other top-level key is rejected, leaving room to extend it.
- An Update with a blank Match Field writes back to the job's own record, and the response must then hold exactly one item.
- Matching problems are errors for that item, never guesses: no match on Update, several Salesforce records sharing a match value, or the same value twice in one response. Upsert with no match inserts.
- At most 1,000 items per response.
- **If the call succeeded but the write into Salesforce failed, the job stays Succeeded**, with the write errors in its result. The remote system already acted, so marking it Failed would invite a duplicate resend. Alerts flag "response not saved" instead.

### ADR-009 Request body storage

**Decision.** `Request_Body__c` is 131,072 characters, the platform maximum, so large bodies can still be replayed. A field's length can grow but never shrink, and this one can't grow further. It is readable by Admins and the Integration User only. Operators see status, result and log but not customer data. Bodies are never selected in bulk; the worker loads one job's body just before its callout. A validation rule makes a stored body write-once.

### ADR-010 Retry and idempotency

**Decision.**

- **Retry only endpoints flagged Retry-safe**, and only on timeouts, connection errors, 408, 429 and 5xx.
- 5 attempts by default (configurable per endpoint; 1 means never retry), waiting 1, 2, 4 and 8 minutes with ±20% jitter. `Retry-After` is honoured up to 24 hours. Waits over 10 minutes go to the hourly poller (P0.1).
- An optional idempotency header name per endpoint. The value is generated once per job and kept for all its retries and replays.

### ADR-011 Package settings in one protected hierarchy custom setting

**Decision.** `Replayr_Settings__c` is a **Protected** hierarchy custom setting. Only Replayr code reads and writes it, in explicit system mode, and admins change it through the console. `JobPoller` is a top-level, public (not global) Schedulable, scheduled hourly at a random minute.

**Why protected.** Public would let any admin or other package change the poller heartbeat. I checked that the visibility can later move from Protected to Public but never back. Salesforce's documentation is ambiguous about whether a *patch* version can make that change, so plan on a minor or major version if it's ever needed.

### ADR-012 Replay and resolve

**Decision.**

- **Replay re-queues the same job**, keeping its idempotency key and history. It is allowed only on finished jobs and never on one marked Not replayable. A job that isn't Retry-safe needs the duplicate risk confirmed, and the log row records who replayed it and whether they accepted that risk.
- **Resolve** closes an *Outcome unknown* job as Succeeded or Failed (or a *Retries used up* job as Failed), with a required note recorded against the person.
- Both are gated by the custom permission `Replayr_Manage_Jobs`. Jobs stay read-only for people, so the confirmation can't be bypassed by editing a status.
- Writes go through a small `without sharing` inner class, `JobActions.PrivilegedWriter`, which touches only jobs the person could already read in user mode, after the permission check. It exists because explicit system mode skips object and field access but **not** record sharing.

### ADR-013 Test mode

**Decision.** An admin can preview the exact request an endpoint would build for a record, and send it only to endpoints flagged Side-effect-free. Preview and Send are separate actions. The reply is shown (status, duration, up to 10,000 characters of body) but never stored, and the Response mapping is never applied, not even as a rolled-back trial. Each send is logged as a job with `Test_Run__c` set. Test jobs are never replayed, and alerts and the health panel leave them out.

Test mode is for those who may edit endpoints, and a send runs as the person testing, who needs principal access themselves.

### ADR-014 Redaction

**Decision.**

- Masking applies wherever Replayr *shows* something: JSON values at any depth, form-encoded bodies, URL query parameters, header values, and name=value pairs in messages.
- Built-in names are always masked, matched inside longer names and ignoring case, spaces, `-` and `_`: authorization, cookie, credential, password, secret, token, apikey, and so on. Each provider can add its own names.
- **The stored request body is never masked**, so a replay sends the real data. It is protected by field access (ADR-009) and by purge.
- XML and JSON nested inside a JSON string are not masked, so the console withholds them rather than show them half-masked (ADR-022).

### ADR-015 Alerts

**Decision.** A custom notification, `Replayr_Alert`, sent by the hourly poller to active Replayr Admins as one grouped message per hour, and only when something needs attention. New *Outcome unknown*, *Retries used up* and *response not saved* jobs are reported once. "Work not moving" (a job waiting over 2 hours) and a failed watchdog repeat every hour while they last. The check time is saved before sending, so a failed send repeats next hour rather than losing problems. v1 sends no email.

### ADR-016 Retention and purge

**Decision.** Finished jobs are kept for 30 days by default, configurable in the console; there is no "never purge". `JobPurge`, a batch of 200 started by the poller once a day as the integration user, deletes **Succeeded and Failed** jobs with their logs and empties them from the recycle bin. Jobs still waiting for a person (*Outcome unknown*, *Retries used up*) and anything in flight are never purged.

### ADR-017 Data model freeze

Before the first promoted version, I froze the core objects:

- `Key__c` on Provider and Endpoint (text 80, unique, External ID, case-insensitive) is the stable handle for flows and data imports, because record Ids differ between sandbox and production. A validation rule limits keys to letters, digits, `-`, `_` and `.`.
- An unused `Provider__c.External_Credential__c` field was removed while that was still possible.
- Reports are enabled on all objects. Field history is tracked on Provider, Endpoint and Mapping, but not on Job, whose status changes on every attempt; the log already records attempts.
- Deferred, because they can be added later: Record Id as External ID, and custom indexes for the claim and alert queries.

### ADR-018 Who may send records

**Context.** The Flow action is global Apex, so anything that can call the API can call it. The check has to live at the entry point, not in the calling context.

**Decision.**

- **Custom permission `Replayr_Send`**, in a Replayr Sender permission set. Without it the action fails the flow, so the admin gets Salesforce's flow-error email instead of sends being silently lost.
- **Endpoints are opened one by one** with `Allow_Sending__c`, off by default. Without this, any sender could reach every configured integration, as the integration user.
- The source record is read in **user mode**: you can only send what you can see. If the endpoint writes the reply back to that record, the sender also needs edit access to it. Otherwise a read-only user could get the integration user to change a record they can't edit.
- **One error message for every configuration reason** a record can't be sent ("Ask your Replayr admin: test mode shows why"), so a caller learns nothing about which keys exist or how they're mapped.
- Provider is a Private object. Rather than ship it Public Read Only (which subscribers could flip back, silently breaking sending), the endpoint lookup and job insert run in a second `without sharing` inner class, `JobCreation.PrivilegedAccess`, after the permission check.

**Consequences.** There are exactly two `without sharing` classes in the package, each a private inner class doing one thing after an explicit permission check. Both are listed in [security-review.md](security-review.md).

### ADR-019 The Flow action contract

**Decision.** Global class `SendWithReplayr`, action "Send with Replayr". Inputs are `endpointKey` (required) and `recordId`; outputs are `jobId` and `error`. There are no body or path overrides, because they would bypass the mapping and its `{!` checks. Inputs can be added later but never removed. One call accepts at most 200 records, each failing or succeeding on its own. The action is meant for the Run Asynchronously path, where a failure never undoes the user's save.

### ADR-020 Template flows

**Decision.** Ship three inactive record-triggered flow templates on Account: send on create, send when a field changes, and send and write the reply back (the last also shows how to handle the action's Error output). Admins copy and adapt them; they never run on their own. I verified in a subscriber org that packaged templates install and can be copied, with one gotcha that is documented in the admin guide.

### ADR-021 One admin console

**Decision.** A single Lightning app page holding one `replayrConsole` component, with sections for Health, Jobs, Providers and endpoints, Mappings, Test mode, and Settings. It is visible to Admins and Operators. Sections that change setup check Admin rights on the server.

- The health panel reuses what is already recorded (poller heartbeat, schedule owner, trigger run-as user, oldest queued job, last alert and purge). It uses the alert's own "work not moving" rule, so the panel and the alert never disagree.
- `replayrConsole` is the only exposed component, and it has no public properties, since released ones can't be removed.
- English only in v1. Moving text to Custom Labels later breaks nothing, while doing it now would add dozens of permanent labels nobody has asked to translate.

### ADR-022 Jobs view: masking fails closed

**Decision.** The Jobs list opens on "Needs a person", with filters for Failed, Waiting, Succeeded and All, and supports bulk replay or resolve of up to 200 jobs. Masked names are read in the same user-mode query as the job. **If the provider can't be read, the job is an error, never shown with only the built-in names masked.** A request body is shown only if `Redactor` can mask it completely; otherwise it is withheld with the reason.

### ADR-023 Credentials: guided setup, no secret-handling wizard

**Decision.** v1 has no wizard that touches secrets. Admins create External and Named Credentials in Setup, following the admin guide. Each Named Credential must also allow the `replayr` namespace for callouts. The console has a **"check this provider"** button that verifies the Named Credential exists, its callouts are enabled, and the integration user has principal access plus Read on `UserExternalCredential`.

**Why.** P0.6 showed a wizard would still need a manual Setup step, and it would put secrets through package code, which is the riskiest thing an AppExchange package can do. The check button needs View Setup and Configuration (P4.2). I chose not to add that to the Replayr Admin set, because it would let every Replayr Admin browse all of Setup. Anyone without it is told to ask a Salesforce administrator.

### ADR-024 Provider, endpoint and mapping editing

**Decision.**

- Providers and endpoints are edited through standard record forms (Lightning Data Service). The platform then enforces field access and shows validation messages beside the field, and console Apex only lists. The console offers no delete; record pages still do, with Salesforce's own warning.
- Mappings are edited in the console and saved through Apex in user mode, because the server runs the same checks a job would (object, merge fields, `{!`, response paths) and refuses a broken mapping with the reason. The target object is typed and validated rather than picked from a list of every object. There is at most one Request and one Response mapping per endpoint.
- Accepted: the save check tells a Replayr Admin whether an object or field exists. Describe data isn't secret, and Replayr Admin is a trusted role.

### ADR-025 Settings and setup section

**Decision.** The console's Settings section lets Admins change the retention period (1 to 3,650 days) and start background work once after setup, which also schedules the poller as the integration user (ADR-003). Settings are written by package code only, because the setting is protected (ADR-011).

---

## Open items

- Test the installed package in a Professional trial org, check Integration licence availability there, and size Replayr's expected platform-event rate against its limits.
- Confirm from Salesforce's patch-version documentation whether a patch may change a protected custom setting's visibility.
