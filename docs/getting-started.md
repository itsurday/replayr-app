# Getting started with Replayr

This guide takes you from a fresh install to your first record sent to an outside system. It's written for Salesforce admins, and you don't need to write any code. Allow about 30 minutes.

**Prefer to watch?** The [video walkthrough](https://github.com/user-attachments/assets/6ac85819-7c89-4524-b27f-886566c71f4a) follows these exact steps in a fresh org. You can also [download it](media/replayr-walkthrough.mp4).

The examples use **httpbin.org**, a free public test API that simply echoes back whatever it receives. Swap in your own system's details when you set up a real integration.

## What you'll need

- Replayr installed in your org (Enterprise, Unlimited, Performance or Developer edition).
- System Administrator access.
- The address of the API you want to send to, and its login details (for example a username and password, or an API key).
- One free **Salesforce Integration** user licence. Enterprise orgs include five.
- [Salesforce CLI](https://developer.salesforce.com/tools/salesforcecli), for one small step (Step 5). Workbench works too, if your company allows it.

## How Replayr works, in one minute

1. A flow hands Replayr a record, for example every new Account.
2. Replayr builds the message from your field mapping and saves it as a **job**.
3. In the background, a dedicated **integration user** sends the job to the outside system.
4. Every attempt is logged. If a call fails, Replayr retries it when that's safe. If it can't be sure, it asks a person instead of guessing.

Your passwords and API keys stay in Salesforce Setup (Named Credentials). Replayr never stores or sees them.

---

## Part 1: Connect the outside system (in Setup)

### Step 1: Create an External Credential (how Salesforce signs in)

1. In **Setup**, search for **Named Credentials** and open the **External Credentials** tab.
2. Click **New** and fill in:
   - **Label**: `Httpbin`
   - **Name**: `Httpbin`
   - **Authentication Protocol**: the one your API uses. The example uses **Basic Authentication**.
3. Click **Save**.
4. On the new credential, find **Principals** and click **New**:
   - **Parameter Name**: `DemoLogin`
   - **Identity Type**: **Named Principal**
   - **Username** and **Password**: your API's login. httpbin accepts any values.
5. Click **Save**.

### Step 2: Create a Named Credential (the API's address)

1. Go back to **Named Credentials** and click **New** on the **Named Credentials** tab:
   - **Label**: `Httpbin API`
   - **Name**: `Httpbin_API`. You'll type this exact name into Replayr later.
   - **URL**: `https://httpbin.org`
   - **External Credential**: `Httpbin`
   - **Generate Authorization Header**: ticked
   - **Allowed Namespaces for Callouts**: `replayr`
2. Click **Save**.

> **Don't skip "Allowed Namespaces".** Without `replayr` there, every call fails with *"the named credential might not exist"*, even though it does.

## Part 2: Create the integration user (in Setup)

All of Replayr's calls are made by one dedicated user, so your colleagues never need access to the API's login.

### Step 3: Create a permission set for the API login

1. In **Setup**, open **Permission Sets** and click **New**:
   - **Label**: `Httpbin API Access`
   - **License**: **Salesforce API Integration**
2. Click **Save**.
3. Open **External Credential Principal Access** and click **Edit**. Move **Httpbin - DemoLogin** to the right and click **Save**.
4. Go back to the **Permission Set Overview**, open **Object Settings**, then **User External Credentials**. Click **Edit**, tick **Read**, and click **Save**.

> **Pick the licence when you create the permission set.** It can't be changed afterwards. If you forget it, assigning the set in Step 4 fails with *"The user license doesn't allow the permission: Read User External Credentials"*. The fix is to create a new set with the licence.

### Step 4: Create the integration user

1. In **Setup**, open **Users** and click **New User**:
   - **First Name**: `Replayr`, **Last Name**: `Integration`
   - **Email**: an address your team monitors
   - **Username**: anything unique, for example `replayr.integration@yourcompany.com`
   - **User License**: **Salesforce Integration**
   - **Profile**: **Minimum Access - API Only Integrations**
2. Click **Save**.
3. On the new user, find **Permission Set License Assignments** and click **Edit Assignments**. Tick **Salesforce API Integration** and click **Save**.
4. Find **Permission Set Assignments** and click **Edit Assignments**. Add **Replayr Integration User** and **Httpbin API Access**, then click **Save**.

Use a dedicated user, not a real person's account and not a System Administrator. People leave companies, and every call runs with this user's access.

### Step 5: Run Replayr's background work as that user

Salesforce only lets you choose this user with a small file. You do this once.

1. Save this as `ReplayrWorkWaiting.platformEventSubscriberConfig-meta.xml`, with your integration user's username:

   ```xml
   <?xml version="1.0" encoding="UTF-8"?>
   <PlatformEventSubscriberConfig xmlns="http://soap.sforce.com/2006/04/metadata">
       <batchSize>2000</batchSize>
       <masterLabel>ReplayrWorkWaiting</masterLabel>
       <platformEventConsumer>replayr__ReplayrWorkWaitingTrigger</platformEventConsumer>
       <user>replayr.integration@yourcompany.com</user>
   </PlatformEventSubscriberConfig>
   ```

2. Put it in a Salesforce DX project folder `force-app/main/default/platformEventSubscriberConfigs/`, then deploy it:

   ```sh
   sf project deploy start --source-dir force-app/main/default/platformEventSubscriberConfigs --target-org <your org>
   ```

3. In **Setup**, open **Platform Events**, then **Replayr work waiting**. Under **Subscriptions**, click **Manage**. Click **Suspend** and confirm, then click **Resume** and confirm. Salesforce only picks up the new user after this restart.

Until this step is done, Replayr sends nothing, but nothing is lost either. Jobs wait safely in the queue.

## Part 3: Set up Replayr (in the Replayr app)

### Step 6: Start the background work

1. Open the **Replayr** app from the App Launcher and go to the **Console** tab.
2. Open **Settings and setup** and click **Start background work**.
3. After a minute, open **Health** and click **Refresh**. It should show:
   - the poller scheduled as **Replayr Integration**;
   - the event trigger running as **Replayr Integration**.

The warning *"The poller hasn't finished a run yet"* clears by itself after the first hourly run.

### Step 7: Add a provider (the outside system)

1. In the Console, open **Providers and endpoints** and click **New provider**:
   - **Provider Name**: `Httpbin`
   - **Named Credential**: `Httpbin_API`, the name from Step 2
   - **Key**: `httpbin`, a short name that never changes
2. Click **Save**, then **Check this provider**. Replayr confirms what it can see and lists anything left to check in Setup.

### Step 8: Add an endpoint (one call to that system)

1. On the provider, click **New endpoint**:
   - **Endpoint Name**: `Send account`
   - **Method**: `POST`
   - **Path**: `/anything`
   - **Key**: `send-account`. The flow uses this in Step 11.
2. Tick only what's true for this call:
   - **Retry-safe**: sending it twice does no harm, so Replayr may retry it automatically.
   - **Side-effect-free**: it changes nothing on the other side, so test mode may send it.
   - **Allow sending from flows and the API**: flows may use this endpoint. It's off by default, for safety.
3. Click **Save**.

If you're not sure about Retry-safe, leave it unticked. Replayr will then never resend on its own, and a person decides instead.

### Step 9: Map your fields

1. On the endpoint, click **New Request mapping**:
   - **Object**: `Account`
   - **Template**: the message to send, with `{{Field}}` wherever a value goes:

   ```json
   {
     "name": "{{Name}}",
     "phone": "{{Phone}}",
     "owner": "{{Owner.Name}}"
   }
   ```

2. Click **Save**. Replayr checks every field name before it saves, so typos are caught now, not when a real record is sent.

### Step 10: Preview with test mode

1. Under **Test this endpoint**, pick any Account and click **Preview**.
2. You'll see the exact request Replayr would send, with secrets masked. Nothing is sent.

**Send a test** really calls the API, as *you*. To use it, give yourself access to the credential too: a second permission set with no licence, granting the same principal access as Step 3.

## Part 4: Send records automatically

### Step 11: Turn on a template flow

Replayr includes three ready-made flows. Each one is a template, so you save your own copy:

| Template | What it does |
| --- | --- |
| Send a record when it is created | Sends each new record |
| Send a record when a field changes | Sends a record when one field changes (Phone in the template) |
| Send a record and write the reply back | Sends each new record and saves the reply onto it |

1. In **Setup**, open **Flows**, click **New Flow**, and search for `Replayr template`.
2. Open **Replayr template: send a record when it is created**.
3. Click **Save** and fill in:
   - **Flow Label**: `Send new accounts to Httpbin`
   - **Show Advanced**, then **Source Template**: type `Replayr` and choose the template from the list.
4. Click **Save**.
5. Open the **Toolbox**, click the **EndpointKey** constant, change its value to `send-account`, then click **Done** and **Save**.
6. Click **Activate**.

> **Don't skip "Source Template".** Without it, Salesforce refuses to save, with *"This flow's Source Template … is not a template or doesn't exist"*.

The template only starts for records whose **Name** isn't blank. Change that condition to pick the records you want to send.

### Step 12: Try it

1. Create a new Account the normal way.
2. In the Replayr Console, open **Jobs**, set **Show** to **Succeeded**, and open the newest job.
3. You'll see the status, every attempt with its HTTP result, and exactly what was sent.

**Before you go live:** give everyone whose changes start a Replayr flow the **Replayr Sender** permission set. Without it, their saves still work, but the record isn't sent, and Salesforce emails the flow error to your admins.

---

## Everyday use

- **Jobs → Needs a person** lists the only calls that need your attention:
  - **Outcome unknown**: the platform stopped mid-call, so nobody knows whether the other side received it.
  - **Retries used up**: every allowed attempt failed.
- **Replay** sends a finished job again. If the endpoint isn't Retry-safe, Replayr asks you to confirm the duplicate risk first.
- **Resolve** closes a job you've checked by hand, with a note.
- Replayr Admins get one grouped Salesforce notification per hour, and only when something needs a look.
- Finished jobs are kept for 30 days by default. You can change this under **Settings and setup**.

## When something goes wrong

| You see | What it means | Fix |
| --- | --- | --- |
| *"the named credential … might not exist"* | Replayr isn't allowed to use the Named Credential | Add `replayr` to its **Allowed Namespaces for Callouts** (Step 2) |
| *"You don't have read permissions on the User External Credential object"* | The integration user lacks Read on User External Credentials | Step 3, point 4 |
| *"The user license doesn't allow the permission: Read User External Credentials"* | The permission set was made without the API Integration licence | Create a new set with **License: Salesforce API Integration** (Step 3) |
| *"We couldn't access the credential(s)"* in test mode | **Send a test** runs as you, and you have no access to the credential | Give yourself principal access (Step 10), or test with Preview only |
| Health: *"The event trigger hasn't run yet"* or a wrong run-as user | The run-as setup isn't finished | Redo Step 5, including Suspend and Resume |
| Flow won't save: *"Source Template … doesn't exist"* | The copy isn't linked to its template | Step 11, point 3 |
| Jobs stay **Queued** | Background work isn't running as the integration user yet | Check Health, then redo Steps 5 and 6 |

For more detail, such as write-back flows and changing the integration user later, see the [admin guide](admin-guide.md).
