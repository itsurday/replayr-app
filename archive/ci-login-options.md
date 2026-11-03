# CI login options for the Dev Hub (P1a.6)

Written 2026-10-24 for future review. **Decision (2026-10-24): option 5** (no Salesforce login in CI for now). CI skips the Salesforce steps until login secrets exist; adding them later (option 1, 2 or 3) switches those steps on without editing the workflow.

## The problem

GitHub Actions must log in to the Dev Hub (the Partner Business Org) without a password or a browser, to create scratch orgs and package versions.

- Since Spring '26, Salesforce no longer lets you create new **Connected Apps** without a support case; the replacement is the **External Client App**.
- Creating a scratch org while logged in to the Dev Hub through an External Client App currently fails with error **C-1016** ([forcedotcom/cli#3515](https://github.com/forcedotcom/cli/issues/3515), still open on 2026-09-29).
- Replayr's pull-request check (`.github/workflows/ci.yml`) creates a scratch org per pull request, so it is directly affected.

## The options

| # | Option | How it works | Setup effort | Reliability | Security |
|---|---|---|---|---|---|
| **1** | **Support case → Connected App + JWT** | Salesforce Support re-enables Connected App creation in the Dev Hub; create a Connected App with a certificate; CI logs in with JWT | Support case (days of waiting), then ~15 min | ✅ Proven path; works for others today | ✅ Key-based, no password, not usable interactively |
| **2** | **External Client App + JWT + pre-release fix** | Current recommended login type, plus Salesforce's pre-release CLI plugin (`@salesforce/plugin-org@eca`, with `SF_SCRATCH_SIGNUP_CONNECTED_APP=PlatformCLI`) that works around the scratch-org bug | ~15 min, no waiting | ⚠️ Depends on a pre-release plugin that testers report working (build `eca.2`); may change until the real fix ships | ✅ Key-based, but a pre-release plugin runs in the same step as the key |
| **3** | **External Client App + JWT, without scratch orgs** | Skip the per-PR scratch org; check pull requests by building a package version (`sf package version create --code-coverage`), which runs all Apex tests in Salesforce's own build environment and avoids the bug | ~15 min, no waiting | ✅ Stable commands only | ✅ Key-based; ⚠️ each PR creates a beta version (counts against the daily limit; can be cleaned up) |
| **4** | **Auth-URL secret** | Log in once in the browser, export an auth URL with a refresh token (`sfdx-url`), store it as a GitHub secret | ~5 min | ⚠️ The refresh token can expire or be revoked; CI breaks until redone | ⚠️ Broadest credential: whoever holds it is logged in as you |
| **5** | **No Salesforce login in CI, for now** | CI runs only offline checks (Code Analyzer now, LWC tests later); deploy-and-test runs locally with `/deploy-test` until option 1–3 is ready | None | ✅ Nothing to break | ✅ No credential stored anywhere |
| 6 | Paid DevOps tool (Gearset, Copado, DevOps Center…) | A third-party or Salesforce tool manages CI and logins | Sign-up, cost | ✅ | Depends on the vendor |

## How they compare

- **Today, no waiting, stable:** 3 or 5.
- **Textbook setup (a fresh org per change):** 1 (after Support) or 2 (pre-release risk).
- **Avoid:** 4 (gives GitHub what is effectively a full login); 6 (overkill for a solo pre-launch project).

## Recommendation (2026-10-24)

**Option 5 now, option 1 in parallel, option 3 as the fallback.**

1. Open the support case now, combined with D1.7: ask Support to (a) re-enable Connected App creation in the Dev Hub and (b) explain why the verified-org link failed.
2. Meanwhile use option 5: CI keeps running Code Analyzer on every pull request; the phase 1a gate ("green on an empty package") is already met, and with no Apex yet a scratch org would test nothing.
3. When Support answers, switch to option 1 (Connected App steps, then enable the Salesforce steps in CI).
4. If Support is slow by the time real Apex arrives (phase 1b), switch to option 3.

## What the CI workflow already supports

`.github/workflows/ci.yml` uses JWT (`sf org login jwt`), so options 1, 2 and 3 share the same login step and secrets (`SF_DEVHUB_USERNAME`, `SF_DEVHUB_CLIENT_ID`, `SF_DEVHUB_JWT_KEY` in the GitHub Environment `ci`). Option 2's workaround is behind the repository variables `SF_ECA_SCRATCH_WORKAROUND` and `SF_ECA_PLUGIN_VERSION` (an exact version, never a tag). Option 3 would need the pull-request job changed from "scratch org + deploy + tests" to "build a package version". Option 5 needs no change: with no secrets set and an empty `force-app`, the Salesforce steps are skipped.

## Sources

- [forcedotcom/cli#3515 — scratch org creation fails with C-1016 via External Client App](https://github.com/forcedotcom/cli/issues/3515)
- [Create an External Client App in Your Org — Salesforce DX guide](https://developer.salesforce.com/docs/platform/sfdx-dev/guide/sfdx-dev-auth-eca.html)
- [Authorize an Org Using the JWT Flow — Salesforce DX guide](https://developer.salesforce.com/docs/platform/sfdx-dev/guide/sfdx-dev-auth-jwt-flow.html)
- [OAuth device flow and External Client Apps — Software Insights](https://www.softwareinsights.dev/posts/salesforce-oauth-device-flow-external-client-apps/)
