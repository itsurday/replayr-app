# Dev setup: test credentials in a scratch org

How I rebuild the test credentials for all four auth types after a scratch org is recreated (scratch orgs last 30 days). Everything here is test-only: `dev/` is not packaged and CI never deploys it. Secrets are always typed into Setup, never into files.

| Auth type | External Credential | Named Credential | Test endpoint |
|---|---|---|---|
| Basic | `Httpbin_Auth` (Basic protocol) | `Httpbin_API` → httpbin.org | Get, `GET /get` |
| API key | `Httpbin_ApiKey_Auth` (Custom, header `X-Api-Key`) | `Httpbin_ApiKey_API` | Headers, `GET /headers` |
| Bearer token | `Httpbin_Bearer_Auth` (Custom, header `Authorization: Bearer …`) | `Httpbin_Bearer_API` | Bearer check, `GET /bearer` |
| OAuth client credentials | `Oauth_Server_Auth` | `Oauth_Server_API` → oauth-server org | Limits |
| OAuth authorization code | `Oauth_Server_Browser_Auth` (via Auth Provider `OAuth_Server`) | `Oauth_Server_Browser_API` → oauth-server org | Limits (browser) |

## 1. Orgs

- `replayr-dev`: `sf org create scratch --definition-file config/project-scratch-def.json --alias replayr-dev --name replayr-dev --target-dev-hub dev-hub --duration-days 30`, then deploy `force-app` and assign `Replayr_Admin`.
- `oauth-server` (plays the outside OAuth server): the same command with `--alias oauth-server --name oauth-server --no-namespace`.
- Note both My Domain URLs (anonymous Apex: `System.debug(URL.getOrgDomainUrl().toExternalForm());`).

## 2. External Client App in oauth-server

External Client App Manager → New: name `Replayr OAuth Test`, Distribution State Local, Enable OAuth.

- Callback URL: `https://<replayr-dev My Domain>/services/authcallback/OAuth_Server`
- Scopes: `api` and `refresh_token, offline_access`
- Flow Enablement: **Enable Client Credentials Flow** only. "Authorization Code and Credentials Flow" is a different, headless flow; the browser flow needs no checkbox.
- Policies → OAuth Policies: client credentials **Run As** = a user of that org.
- Changes can take about 10 minutes to apply.

## 3. Auth Provider in replayr-dev

Not in the repo, because it holds the consumer secret. Auth. Providers → New, Provider Type **Salesforce**:

- Name `OAuth Server`, URL Suffix **`OAuth_Server`** (the External Credential refers to this exact name; Setup-created records get no `replayr__` prefix)
- Consumer Key and Secret from step 2
- Authorize Endpoint `https://<oauth-server My Domain>/services/oauth2/authorize`, Token Endpoint `…/services/oauth2/token`
- Default Scopes exactly `api refresh_token` (a typo gives `OAUTH_APPROVAL_ERROR_GENERIC` after a successful login)
- PKCE **on**; "Include Consumer Secret in SOAP API Responses" **off**

## 4. Deploy dev/ (in this order)

1. If oauth-server changed, edit its My Domain URL into `Oauth_Server_Auth` (token URL), `Oauth_Server_API` and `Oauth_Server_Browser_API`.
2. Credentials first: `sf project deploy start --source-dir dev/main/default/externalCredentials --source-dir dev/main/default/namedCredentials --target-org replayr-dev`
3. Then the permission set (a combined deploy fails with "Unable to find ExternalCredentialPrincipal"): `sf project deploy start --source-dir dev/main/default/permissionsets --target-org replayr-dev`, and `sf org assign permset --name Replayr_Dev_Httpbin --target-org replayr-dev`

## 5. Data

`sf apex run --file dev/scripts/dev-data.apex --target-org replayr-dev`

## Load test: a 200-record flow

1. Edit the integration user's username into `dev/main/default/platformEventSubscriberConfigs/ReplayrWorkWaiting.platformEventSubscriberConfig-meta.xml`, deploy it with `dev/main/default/flows`, then in Setup → Platform Events → Replayr Work Waiting → Subscriptions, **Suspend** and **Resume** the trigger.
2. `sf org assign permset --name Replayr_Dev_Httpbin --on-behalf-of <integration username> --target-org replayr-dev`
3. `sf apex run --file dev/scripts/gate4a-setup.apex --target-org replayr-dev` (endpoint `httpbin-post`; once per org), then `dev/scripts/gate4a-run.apex` (200 accounts named "Replayr gate NNN"; the active flow sends them).
4. Before deploying `JobWorker` or `JobPoller`, or running tests, abort the poller the hand-off scheduled: `for (CronTrigger t : [SELECT Id FROM CronTrigger WHERE CronJobDetail.Name = :replayr.JobPoller.JOB_NAME]) System.abortJob(t.Id);`. Afterwards `EventBus.publish(new replayr__Replayr_Work_Waiting__e());` schedules it again as the integration user.

## 6. Secrets (replayr-dev Setup → Named Credentials → External Credentials → principal → Edit)

Made-up values only for httpbin, which is public.

| External Credential | Principal | Enter |
|---|---|---|
| Httpbin Auth | Httpbin_User | Username `replayr`, any password |
| Httpbin API Key Auth | ApiKey_User | Authentication parameter `ApiKey` (exact case) |
| Httpbin Bearer Auth | Bearer_User | Authentication parameter `Token` |
| OAuth Server Auth | OAuth_User | Client ID and Client Secret from step 2 |
| OAuth Server Browser Auth | Browser_User | ▼ **Authenticate**, log in to oauth-server, Allow |

## Errors seen and what they meant

| Message | Cause |
|---|---|
| "…the named credential "X" might not exist" | Named Credential missing |
| "The external credential isn't fully configured" | Principal has no credentials yet (step 6) |
| "Field X.ApiKey does not exist" | Authentication parameter not added, or name spelled differently |
| Header arrives as literal `{!…}` text / bearer 401 | "Allow merge fields in HTTP header" off on the Named Credential |
| `OAUTH_APPROVAL_ERROR_GENERIC` after login | Scope typo in the Auth Provider, or External Client App changes not yet applied |
