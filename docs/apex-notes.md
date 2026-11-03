# Apex and platform field notes

Platform behaviour that surprised me while building Replayr. Each item was reproduced in a scratch org, and several of them shaped the design. Worth a read before writing Apex for a managed package.

## Language

- **Reserved words** that look like ordinary names: `then` and `bulk` can't be used as variable or constant names (compile error).
- **`String.getChars()` treats backslash sequences as escapes**: `'a\\"'.getChars()` gives `(97, 34)` and `'a\\b'` gives `(97, 8)`. Use `charAt(i)` to read the real characters.
- **Names ignore case, so a local variable silently hides a constant of the same name in another case**: `Integer colon` inside a method hid `static final Integer COLON`, and the class compiled with no warning (anonymous Apex refuses it: "Duplicate field"). Give character constants a suffix such as `COLON_CHAR`.
- **Strings compare case-insensitively with `==`**; use `equals` for a case-sensitive comparison.
- **`Id.getSobjectType()` throws `SObjectException`** for an Id whose key prefix belongs to no object in the org; it does not return null.
- **Record number fields arrive as `Decimal`, `Integer` or `Long`, never `Double`**, latitude included. JSON numbers arrive as `Integer`, `Long` (large whole numbers) or `Decimal`.
- **`Date.valueOf` rolls an impossible day forward** (2026-02-30 becomes March); compare the result back to the input to reject it.

## SOQL and describe

- **Dynamic SOQL can't bind a `List<Object>`** (`Invalid bind expression type of ANY for column of type String`). Bind a list of the column's own type, for example `(List<Object>) Type.forName('List<String>').newInstance()`.
- **`SELECT Id, Id` is rejected**: when the field to select may itself be `Id`, select it once.
- **Describe in a namespaced org:** an object name resolves without the `replayr__` prefix, but a **field** of a package object needs it (`replayr__Named_Credential__c`), in mappings too.
- **Code Analyzer flags `SObjectType.getDescribe()` as High** (`EagerlyLoadedDescribeSObjectResult`), which fails CI. Use `getDescribe(SObjectDescribeOptions.DEFERRED)`, or `String.valueOf(SObjectType)` for just the name.

## Fields, validation rules and DML

- **Text fields are trimmed before validation rules run**: `'Idempotency-Key\n'` saves as `Idempotency-Key` and passes the rule. Leading and trailing whitespace can't be tested as invalid.
- **A required custom field can't have field permissions** in a permission set (a documented platform rule, not tried here); it is always readable and editable. Making it optional later means adding field permissions in the same change, or user-mode reads return nothing.
- **Updating a record that still holds its master-detail field fails** as a user without reparenting (`CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY`, "fields being inaccessible … Provider__c"). Update a new sObject with only the Id and the changed fields.
- **System mode doesn't skip record sharing**: in a `with sharing` class, `WITH SYSTEM_MODE` and `AccessLevel.SYSTEM_MODE` skip object and field access but still apply sharing, so a user who can't see a Private provider can't find its endpoints or save a job pointing at one. Hence the small `without sharing` classes `JobActions.PrivilegedWriter` and `JobCreation.PrivilegedAccess`
- **Formula `UPPER`/`LOWER` take a locale**: pass `"en_US"` when comparing against fixed names, so a Turkish user's `i` doesn't become `İ`.

## Custom settings and scheduled jobs

- **A user can never create or update a custom setting's fields.** Field permissions on custom-setting fields are silently dropped from permission sets (deploy succeeds, no FieldPermissions rows), and describe reports the field as not createable or updateable. Plain `upsert` failed with "fields being inaccessible" even from a `with sharing` class; only `Database.upsert(record, true, AccessLevel.SYSTEM_MODE)` works. Without `customSettingAccesses` in the user's permission set the error is "Access to entity denied".
- **Plain DML is checked against the running user's field access here**, not only `as user` DML: a test inserting a Job with a field the runner can only read failed with "fields being inaccessible", as did the custom-setting upsert above. Set fields that only package code writes with `Database.insert(record, true, AccessLevel.SYSTEM_MODE)`.
- **A `WITH USER_MODE` query in a batch's `start()` fails with "Variable does not exist: tmpVar1"** (a `QueryException`) when the user can't read the object: a misleading message for missing access.
- **`Database.emptyRecycleBin` succeeds but the rows still show with `ALL ROWS`**, in the same transaction and the next (tried with a throwaway Provider in `replayr-dev`): removal happens later, in the background. A test can't check the recycle bin was emptied.
- **`CronTrigger` can't be queried without "View Setup and Configuration"** ("sObject type 'CronTrigger' is not supported"). Code that runs as the integration user detects an existing scheduled job by the duplicate-name `AsyncException` from `System.schedule`, whose message names the job.
- In tests, `Test.stopTest()` runs a job scheduled with `System.schedule`, which proves a top-level Schedulable's code really runs (inner classes never do, P0.2b).

## Platform events and Queueables

- **Publishing an event needs Create on it, even from Apex**: `EventBus.publish` by a user without it fails with "Access to entity denied" (`CANNOT_INSERT_UPDATE_ACTIVATE_ENTITY`) in its `SaveResult`, not an exception (spike P4.1).
- **An event with no custom fields deploys and publishes** (P4.1).
- **Create on a platform event requires Read on it** in a permission set: the deploy fails with "Permission Create ... depends on permission(s): Read".
- **Publishing an event counts as a DML statement** (`Limits.getDmlStatements()` rises by one), so tests that count a method's DML must include it.
- **In a test, `Test.getEventBus().deliver()` runs an event trigger as Automated Process**, since no subscriber config applies there; test the integration-user path by calling the handler directly.
- **A platform-event trigger enqueued 50 Queueables in one run**, and an enqueue refused for a duplicate signature still counts toward the limit (`Limits.getQueueableJobs()` rose by one) (P4.1).
- **A duplicate signature (`AsyncOptions.DuplicateSignature`) refuses a second job only while the first is Queued**, with `System.DuplicateMessageException`; **while the first is Processing, a second is accepted**. So a running Queueable can enqueue its next link under its own signature, but the signature can't stop a second chain starting during a link's run (P4.1).
- **Scratch orgs end a Queueable chain after 5 links**, even with the Enterprise edition: the sixth `System.enqueueJob` from a running link throws an `AsyncException` (as in Developer and Trial orgs). Replayr then starts a fresh chain through the work-waiting event (decisions.md, ADR-004).
- **`System.DuplicateMessageException` is not an `AsyncException`** (checked with `instanceof`), so the two can be told apart in one catch.
- **In the namespaced `replayr-dev`, `PlatformEventSubscriberConfig.platformEventConsumer` took the trigger's name without the namespace prefix** (`ReplayrWorkWaitingTrigger`); **in a subscriber org it takes the prefixed name** `replayr__ReplayrWorkWaitingTrigger` (verified in an installed beta).
- **A custom notification sent by the integration user reaches the Replayr Admin's bell:** the packaged poller, running as a Salesforce Integration licence user, delivered "Replayr: jobs need attention" in a subscriber org; no extra user permission was needed (verified in an installed beta).
- **The run-as user of an event trigger can only be set through the Tooling or Metadata API** (`PlatformEventSubscriberConfig`); Setup only shows it and offers Suspend and Resume (P4.1).

## Callouts and credentials

- **ConnectApi reads a Named Credential's callout switch:** `ConnectApi.NamedCredentials.getNamedCredential(name).calloutStatus` (`Enabled`), its External Credentials, and through `getExternalCredential` their principals' Ids; `SetupEntityAccess` with `SetupEntityId` = a principal's Id lists the permission sets granting it. SOQL can't read `ExternalCredential`, `ExternalCredentialParameter` or `UserExternalCredential` (P4.2).
- **All of it needs "View Setup and Configuration"** (which itself needs View Roles): without it ConnectApi throws `NoAccessException: Insufficient Privileges`, and SOQL on `NamedCredential`, `SetupEntityAccess` and other users' `PermissionSetAssignment` is refused, even from Apex and even for a Replayr Admin (P4.2).
- **In the namespaced dev org, package code's bare Named Credential name was matched against the package's namespace** in ConnectApi (`Missing_API` reported as `replayr__Missing_API`). **In a subscriber org, ConnectApi's `getNamedCredential` from package code misses the subscriber's own unnamespaced credential, though callouts find it** by the bare name once it lists `replayr` in its allowed namespaces (verified in an installed beta). Its list, `getNamedCredentials()`, doesn't show it to package code either; **SOQL on `NamedCredential` with `NamespacePrefix = NULL` does**, but gives no callout status or External Credentials (P4.2).
- **A packaged permission set loses its Read on `UserExternalCredential` when installed**; the subscriber's own set must grant it (verified in an installed beta).
- **Merge fields in a callout body:** with a Named Credential's "Allow Formulas in HTTP Body" **on**, `{!$Credential…}` in a request body is replaced by the stored secret; **off**, the literal text is sent. Headers behave the same with "Allow Formulas in HTTP Header". Replayr rejects every `{!` in templates, rules and finished bodies.

## App branding

- **A Lightning app's logo is a ContentAsset, not a Document:** `CustomApplication.brand.logo` takes the asset's name (`Replayr_Logo`), and a `Folder/Document` reference fails with "no ContentAsset named … found". The asset ships as `contentassets/<Name>.asset` (the image bytes) plus its `-meta.xml`; the App Launcher then shows it.

## Lightning web components calling Apex

- **An `@AuraEnabled` method whose parameter is a custom Apex class fails in a real org** with "An internal server error has occurred" before any Apex runs (the debug log shows the code unit start and finish with no statements); `{ get; set; }` properties didn't help. Seen in a namespaced scratch org and in an installed beta. Take plain parameters (String, Id, Boolean, Datetime and so on), and pass structured data such as Response rules as a JSON string that Apex parses and validates. Custom classes as **return** types work.
- **Neither Apex tests nor Jest catch it:** Apex tests call the method directly and Jest mocks it, so only clicking through the page in an org does. Click through every changed console action before a beta.

## Running tests

- **At most 500 test classes can be queued per 24 hours** (the greater of 500 and 10 × the org's test classes). Past it, every asynchronous run, even of one class, fails with `UNKNOWN_EXCEPTION` and no detail. Check with `SELECT Status, COUNT(Id) FROM ApexTestQueueItem WHERE CreatedDate = TODAY GROUP BY Status`. Synchronous runs (`--synchronous`, one class each) still work but give no org-wide coverage.
- **Async runs count each `@TestSetup` as a test**, so their "Tests Ran" is higher than the sum of synchronous per-class runs.
- **Inside a test, a Queueable can't enqueue another Queueable**: the worker chain's next link fails and its claim is rolled back. Call such code directly (synchronously) where it attaches no finalizer, or assert only one level.
- **A synchronous callout in a test fails with "You have uncommitted work pending"** because the `@TestSetup` inserts count as uncommitted work in the test's transaction. Call it between `Test.startTest()` and `Test.stopTest()`, and make only one such call per test if the code under test writes after its callout.
- **Tests see the org's real scheduled jobs:** while a real `JobPoller` is scheduled in `replayr-dev`, `JobPollerTest` and `WorkWaitingTest` fail on "scheduled the first time" and "no poller"; a deploy that changes `JobWorker` or `JobPoller` is also refused while it is scheduled. Abort it first (docs/dev-setup.md).
- **`HttpRequest.getBody()` returns `''`, not null, when no body was set**.
- **`System.attachFinalizer` fails outside a Queueable** (`not allowed in this context`), so a link that attaches one can't be run by calling `execute()` directly.

## Test data in the scratch org

- Salesforce **stores Email in lower case**; a test of case-insensitive matching must vary the case in the incoming data, not in the stored record.
- `replayr-dev` has **no `Account.AccountNumber`** field, and the dev user has no edit access to `Account.Site`; use `Phone`, `Description` or `NumberOfEmployees` instead.
- Setting `BillingLatitude` requires `BillingLongitude` too (`FIELD_INTEGRITY_EXCEPTION`).
- Tests that insert Replayr records must run as `ReplayrTestAccess.runner()`: only Replayr's permission sets grant field access, and the package build org has no other source of it.
