# Security review: scanner results

Evidence for the AppExchange security review submission. Rerun before each submission and update this file.

## Salesforce Code Analyzer v5

Run on 2026-11-02 over `force-app`, with the `AppExchange` and `Security` rule selectors:

```
sf code-analyzer run --target force-app --rule-selector AppExchange --output-file scan-AppExchange.html
sf code-analyzer run --target force-app --rule-selector Security --output-file scan-Security.html
```

Result: no Critical or High findings. The 6 Moderate findings below are all false positives.

| Rule | Where | Why it is a false positive |
|------|-------|----------------------------|
| AvoidHardcodedCredentialsInFieldDecls | `ConsoleProviderCheck.USER_EXTERNAL_CREDENTIAL` | It's the API name of a standard object (`'UserExternalCredential'`), used to check access to it. It is not a credential. |
| AvoidHardcodedCredentialsInFieldDecls | `JobWorker.CHAIN_SIGNATURE` | A fixed label (`'replayr-job-chain'`) that marks Replayr's own Queueable chain. It authenticates nothing. |
| ProtectSensitiveData | `Provider__c.Key__c` | A name the admin picks so that flows and Apex can refer to a provider. It is not a secret. |
| ProtectSensitiveData | `Endpoint__c.Key__c` | The same idea for endpoints: the name a flow or Apex passes to send through an endpoint. |
| ProtectSensitiveData | `Job__c.Idempotency_Key__c` | A key that detects duplicate sends of the same request. It grants no access. |
| ProtectSensitiveData | `Provider__c.Named_Credential__c` | The developer name of a Named Credential. Credentials live only in External and Named Credentials, never in Replayr's objects. |

### Graph Engine paths to check by hand

The Graph Engine finds a source and a sink on some entry points. It then stops with an internal error and asks for a manual check that the path is safe. Which paths it stops on varies from run to run. Seen so far:

- `ConsoleHealth.read`: counts jobs with a static SOQL query `WITH USER_MODE`. The bind variables are package constants (`JobWorker.OUTCOME_UNKNOWN`, `JobWorker.DEAD`).
- `ConsoleTestMode.run`: gated by the `Replayr_Manage_Jobs` custom permission and `Endpoint__c` edit access. Its reads and writes run in user mode in `TestMode`.
- `SendWithReplayr.send` (through `JobCreation`): gated by `Replayr_Send`. It may write back only to records the person can edit; `JobCreation` checks that.

## Snyk

Run with the Snyk CLI (organisation `itsurday`) by `bash scripts/snyk-report.sh`. It writes JSON and HTML reports to `snyk-reports/<yyyy-mm-dd_hhmm>/`, which git ignores. `.snyk` excludes two folders: `archive/`, spike code that is never deployed or packaged (`.forceignore` also excludes it), and `snyk-reports/` itself. It needs `npx snyk auth` once.

Latest run, 2026-11-03 (`snyk-reports/2026-11-03_0835/`):

- **Snyk Open Source:** no vulnerable paths. The npm dependencies are only development tools (ESLint, Jest, Prettier). None of them ships in the package, which contains no third-party JavaScript libraries.
- **Snyk Code:** 2 Low findings, and no High or Medium.

| Rule | Where | Why it isn't a vulnerability |
|------|-------|------------------------------|
| Access Violation (class not `with sharing`) | `PermissionSetHolders` | `inherited sharing`, not `without sharing`, on purpose. Its queries are `WITH SYSTEM_MODE`, because only admins can read permission set assignments and its callers run as other users (decisions.md, ADR-003). They filter through User (`Assignee.IsActive`), which has record sharing, so `with sharing` could hide holders in an org whose User sharing is Private. It returns only user Ids. |
| Access Violation (class not `with sharing`) | `JobCreation.PrivilegedAccess` | `without sharing` on purpose, one of the two documented exceptions (decisions.md, ADR-018). Senders can't see Replayr's Private providers, so without it no flow could send. It finds an endpoint by key and inserts jobs only after the `Replayr_Send` check. The sent record is read in user mode outside this class. Snyk Code findings can't be ignored from the CLI, so this one stays open in the report. |

The first run, the same day, found 34 Low findings; 32 were fixed:
- **Test classes:** all 37 test classes are now declared `with sharing`. The full suite still passes.
- **Test constants:** two test constants that Snyk read as credentials were renamed. They are made-up values that prove the console's masking.

## Flows

Code Analyzer v5's `flow` engine (15 rules, 3 of them Security) already runs in the scans above, and finds no Security issue in the three template flows. Its full rule set (`--rule-selector flow`, run 2026-11-02) adds:

- **4 High `MissingFaultHandler`:** "Send with Replayr" in all three templates, and the write-back template's task step, have no fault path. Not a security finding, and kept on purpose:
  - "Send with Replayr" faults in one case only: the person whose change fired the flow lacks the Replayr Sender permission set. Failing the flow then makes Salesforce email the flow error, naming the permission set, to the admins set to receive flow errors (admin guide, "Let users send records"). Only an admin can fix that, so the email is the right alert.
  - A fault path would end the flow normally and stop that email. It would only move the alert to the record's owner, who can't grant permission sets.
  - Every other problem with a record (an unknown key, an endpoint not open to flows, a record the person can't see) comes back in the action's Error output, not as a fault. The write-back template turns that into a task for the record's owner.
  - A fault path's own task step would also be an element that can fault, so the rule would flag it in turn. The finding doesn't go away, it only moves.
- **9 Low `MissingDescription`** on template elements.

To consider later: [Lightning Flow Scanner](https://github.com/Flow-Scanner), a third-party, open-source Flow linter (sf plugin and VS Code extension), as a one-off cross-check of the templates. Its rules overlap heavily with Code Analyzer's `flow` engine, and the security review asks only for Code Analyzer and the portal scanner, so it is optional. The repository first suggested for it (`Flow-Scanner/lightning-flow-scanner-appexchange-seo`) returned 404 on 2026-11-02.

## Partner Security Portal: Source Code Scanner

Not run yet. The ISV partner must start it from the Partner Security Portal, with their partner login, against the packaging org or the package version.
