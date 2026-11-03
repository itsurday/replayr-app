# Replayr admin guide

For Salesforce admins installing Replayr in their org. It covers the one-time setup that the platform doesn't let a package do for itself, and how to start sending records from Flow.

## Run background work as the integration user

Replayr sends every call from the background, as one dedicated integration user that has access to your API credentials. When a flow or a replay saves work, Replayr publishes a "Replayr work waiting" event, and a trigger on that event starts the work. Salesforce runs that trigger as the Automated Process user unless you tell it otherwise, and Automated Process has no access to your credentials.

**Until you complete the steps below, Replayr sends nothing.** Jobs wait safely in the queue, and nothing is lost; they go out once setup is done. Replayr's hourly poller is also scheduled by this setup, so it doesn't run before it either.

### 0. Choose the integration user

Use a dedicated user that exists only for Replayr: ideally a Salesforce Integration licence user, or another API-only user. Never a System Administrator or a person's own account: every call, and every write of a response back into Salesforce, runs with this user's access, and a person can leave the company. The user needs:

- the **Replayr Integration User** permission set (Replayr checks for it; without it the trigger starts nothing),
- access to your External Credential's principal, and Read on the **User External Credential** object, both in a permission set of your own. Replayr's permission set can't grant either: it can't reach your credentials, and Salesforce drops the User External Credential permission from packaged permission sets. Without the Read, every call fails with "You don't have read permissions on the User External Credential object."

Each Named Credential Replayr calls must also allow Replayr's namespace: in Setup → Named Credentials, edit it and add `replayr` to **Allowed Namespaces for Callouts**. Without it, every call fails with "the named credential … might not exist", even though it does.

Don't give this permission set to the people who send records: they need only **Replayr Sender**.

Salesforce lets you choose the trigger's user only through its Metadata or Tooling API, not in Setup. You do it once, with a small file.

### 1. Create the file

Save this as `ReplayrWorkWaiting.platformEventSubscriberConfig-meta.xml`, with your integration user's username in `<user>`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<PlatformEventSubscriberConfig xmlns="http://soap.sforce.com/2006/04/metadata">
    <batchSize>2000</batchSize>
    <masterLabel>ReplayrWorkWaiting</masterLabel>
    <platformEventConsumer>replayr__ReplayrWorkWaitingTrigger</platformEventConsumer>    <user>replayr.integration@yourcompany.com</user>
</PlatformEventSubscriberConfig>
```

### 2. Deploy it

Either way works:

- **Salesforce CLI:** put the file in a project's `force-app/main/default/platformEventSubscriberConfigs/` folder and run `sf project deploy start --source-dir force-app/main/default/platformEventSubscriberConfigs --target-org <your org>`.
- **Workbench:** zip the file in a `platformEventSubscriberConfigs` folder with a `package.xml` listing the type `PlatformEventSubscriberConfig` and the member `ReplayrWorkWaiting`, then use Migration → Deploy. Workbench is a community tool, not a Salesforce product, and you sign in to your org through it: use it only if your security policy allows.

### 3. Restart the subscription

Salesforce applies the new user only after a restart. In Setup, open **Platform Events → Replayr work waiting → Subscriptions**, choose **Suspend** on the Replayr trigger, then **Resume**. The Subscriptions list now shows your integration user.

Repeat step 3 whenever you change the user in the file.

### 4. Start it once and check

The hand-off runs the next time work is saved, so set it off once: in the Replayr console, open **Settings and setup** and press **Start background work**. Or send a record through a Replayr flow, or, as an admin with the Replayr Admin set, run this line in the Developer Console (Debug → Open Execute Anonymous Window):

```apex
EventBus.publish(new replayr__Replayr_Work_Waiting__e());
```

It only says "work is waiting"; nothing is sent unless jobs are queued. Then check that the Subscriptions list shows your integration user. The console's **Health** section also shows the user the hand-off ran as, and warns if it isn't the integration user.

When it runs as the integration user, Replayr also schedules its hourly poller as that user, so you don't schedule it yourself. The poller stays owned by that user: if you later replace the integration user, delete the scheduled job "Replayr poller" (Setup → Scheduled Jobs) after changing the file and restarting the subscription, and set the hand-off off again so the new user schedules it.

## Let users send records

First open the endpoint to flows: tick **Allow sending from flows and the API** on it. Only endpoints with this ticked can be used, because anyone with the Replayr Sender permission set can send any record they can see to them.

In a record-triggered flow, add the **Send with Replayr** action (category Replayr) on the **Run Asynchronously** path, with the endpoint's **Key** and the record's Id. Use the asynchronous path: there, a problem with sending never undoes the user's save. Never use it on a **Scheduled** path: that runs as the Automated Process user, who can't send, so every record would fail.

Every user whose changes fire a Replayr flow needs the **Replayr Sender** permission set. Without it the action fails the flow, and Salesforce emails the flow error, naming the permission set, to the flow's last editor or the admins set to receive flow errors. Any other problem with one record (an unknown key, an endpoint not opened to flows, a record the user can't see) leaves that record unsent with the same short message in the action's **Error** output; the other records are still sent. Check **Error** in your flow if a record must not go unsent, and use test mode on the endpoint to see the exact reason.

## Start from a template flow

Replayr comes with three record-triggered flow templates. They are inactive and never run on their own. To use one:

1. In **Setup → Flows**, click **New Flow** and search for "Replayr template"; the three appear under **Templates**. Open one.
2. Click **Save**. In the dialog, give your copy a name, click **Show Advanced**, and in **Source Template** type "Replayr" and **choose the template from the list**. Without this step Salesforce refuses to save, with "This flow's Source Template … is not a template or doesn't exist".
3. Adapt the copy (below), save it and activate it.

Each is built on Account; change the object to the one your endpoint's Request mapping is for.

| Template | Sends | Adapt |
| --- | --- | --- |
| Replayr template: send a record when it is created | each new record | the object, and **EndpointKey** |
| Replayr template: send a record when a field changes | a record whenever one field changes (Phone in the template) | the object, the field in the start conditions, and **EndpointKey** |
| Replayr template: send a record and write the reply back | each new record, to an endpoint whose Response mapping writes the reply back to it; gives the owner a task when a record can't be sent | the object, **EndpointKey**, and the task if you prefer another way to tell someone |

The two templates that send new records start only when **Name** isn't blank: that is an example entry condition, so replace it with one that picks the records you want sent (keep a condition: it stops the flow from starting at all for other records). In every copy, set the constant **EndpointKey** to your endpoint's Key, and tick **Allow sending from flows and the API** on that endpoint. The write-back itself is set on the endpoint (a Response mapping that is an Update with a blank Match Field), not in the flow; users whose changes fire it need edit access to the record as well as the Replayr Sender permission set.

Two things to watch when you adapt them:

- **The write-back template's task** goes to the record's owner, about the record. On an object whose owner can be a queue (such as Lead or Case), or one that doesn't allow activities, change or remove that step, or it fails when a record can't be sent.
- **Never write back to the field a flow watches.** If an endpoint's reply updates the very field that the field-change template starts on, each reply starts another send.
