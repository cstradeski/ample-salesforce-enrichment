# Post-deploy steps

After deploying this package to a sandbox or production org, complete the following.

## 1. Set your Amplemarket API key on the External Credential

The package ships the `Amplemarket_External` external credential, the `AmplemarketBearer` named principal, the `Authorization: Bearer …` custom header, and the principal-access grants on both perm sets. The only piece you have to add post-install is the actual API key (Salesforce won't let packages ship secret values).

1. Setup → **Named Credentials** → tab **External Credentials** → open **Amplemarket External**
2. Click the **AmplemarketBearer** principal → **Authentication Parameters** → **New**
   - Name: `Token`
   - Value: `<your Amplemarket API key>`
3. Save

That's it. The Named Credential will now inject `Authorization: Bearer <your key>` on every Apex callout. To rotate, just edit the `Token` parameter value.

## 2. Assign permission sets

| Permission set | Who gets it | Grants |
| --- | --- | --- |
| **Amplemarket Admin** | The 1–2 people who manage the configuration | Settings tab + LWC, custom permissions `Manage Amplemarket Settings` and `Run Amplemarket Enrichment`, full read/write on `Enrichment_Log__c`, access to the External Credential principal |
| **Amplemarket User** | Anyone who should see the *Enrich with Amplemarket* action on a record | Apex class access to the invocable + service, custom permission `Run Amplemarket Enrichment` (drives action visibility — see step 3), read/create on `Enrichment_Log__c`, access to the External Credential principal |

```bash
sf org assign permset --name Amplemarket_Admin --target-org <yourOrg>
sf org assign permset --name Amplemarket_User --target-org <yourOrg>
```

## 2c. Surface the Field Outcomes related list on Enrichment Log

The metadata creates `Enrichment_Log_Field__c` with a master-detail to `Enrichment_Log__c`, which gives you a *Field Outcomes* related list on every Enrichment Log record. To make it visible:

1. Setup → Object Manager → **Enrichment Log** → Page Layouts → edit the layout used by your Enrichment Log records
2. From the palette → **Related Lists**, drag *Field Outcomes* into the related-list section
3. Click the wrench icon on the related list and add useful columns: *Salesforce Field*, *Amplemarket Field*, *Status*, *Old Value*, *New Value*
4. Save

After enrichment runs you'll see one child row per output mapping with the status (`Applied`, `Skipped - Already Populated`, `Skipped - No Value`, or `Error`).

## 3. Add the Quick Action to each object's record page (with permission-gated visibility)

Quick Actions are deployed but not pinned to record-page layouts automatically. To make the **Enrich with Amplemarket** button visible *only* to users granted the `Run Amplemarket Enrichment` custom permission, configure it via **Dynamic Actions** on the Lightning record page rather than via page layout.

For **Lead**, **Contact**, and **Account**:

1. Open a record of that object → gear icon → **Edit Page** (Lightning App Builder)
2. Select the **Highlights Panel** component → in the right-hand panel click **Upgrade Now** (or **Enable Dynamic Actions** / **Add Action**) to switch from page-layout-driven actions to Dynamic Actions
3. Click **Add Action** → choose **Enrich with Amplemarket**
4. With that action selected, click **Add Filter** and set:
   - Field: `$Permission`
   - Permission: `Run Amplemarket Enrichment`
   - Operator: `Equal`
   - Value: `True`
5. Optional: reorder actions, then **Save** and **Activate** the page

Users without the `Run Amplemarket Enrichment` custom permission will not see the button at all. Users with it (granted by either the **Amplemarket Admin** or **Amplemarket User** perm set) will see it.

> If your org hasn't enabled Dynamic Actions for standard objects yet, an alternative is to drag the action into the **Mobile & Lightning Actions** section of the page layout — but in that mode the button is visible to everyone, and the custom permission has no effect on visibility.

## 4. Configure field mappings

1. App Launcher → **Amplemarket Enrichment** → **Amplemarket Settings** tab
2. For each tab (Lead / Contact / Account):
   - Pick a *Salesforce field* for each *Amplemarket match key* you want to use as input (e.g. Lead.Email → `email`).
   - Toggle **Reveal email** / **Reveal phone** if you want the API to consume reveal credits to return verified contact details.
   - Add **Output Fields** rows: `[Amplemarket field] → [Salesforce field]`. These fields will be written back when enrichment runs.
3. Click **Save** — mappings persist immediately as `Amplemarket_Mapping__c` records.

### One-time cleanup of the old CMDT (if you previously deployed the CMDT version)

If your org has the old `Amplemarket_Enrichment_Mapping__mdt` Custom Metadata Type from a prior deployment, remove it:

1. Setup → **Custom Metadata Types** → next to *Amplemarket Enrichment Mapping*, click **Manage Records**, delete any rows
2. Setup → **Custom Metadata Types** → click **Del** next to *Amplemarket Enrichment Mapping* itself

The new project doesn't ship this CMDT, so it will linger as orphan metadata in your org until you delete it manually.

## 4b. (Optional) Enable permission-free auto-enrichment

The package ships a second flow action, **Enrich with Amplemarket (Async, No User Permissions)**, for automated flows (record-triggered / scheduled / autolaunched) where the user who triggers the flow may not hold any Amplemarket permissions.

**How it differs from the standard action**

| | Enrich with Amplemarket | Enrich with Amplemarket (Async) |
| --- | --- | --- |
| Callout runs as | The user running the flow | The admin who enabled automation |
| Triggering user needs perm set + External Credential | **Yes** | **No** |
| Timing | Synchronous — returns field-level results | Asynchronous — returns "queued" |
| Best for | Screen flows / quick actions | Record-triggered & automated flows |

Salesforce blocks a Named Credential callout when the *running user* lacks access to the External Credential principal, and no Apex setting overrides that. This action sidesteps it by writing an **Enrichment Request** row; a scheduled job drains the queue and does the callouts. Scheduled Apex runs as the user who scheduled it, so *your* Amplemarket access is what gets used.

**Setup — all in the UI, no CLI required.**

1. App Launcher → **Amplemarket Enrichment** → **Amplemarket Credit Tracking** tab
2. Scroll to **Automated Enrichment**
3. Turn on **Enable automated enrichment**, choose how often the queue is checked (5, 10, 15, 20, 30 or 60 minutes), and click **Save**
4. The status line confirms who it runs as and when the next run is. Use **Run now** to drain the queue immediately instead of waiting.

Whoever clicks Save becomes the run-as user, so **save it as an admin who holds the Amplemarket Admin or Amplemarket User permission set**. If someone else later re-saves, a warning badge appears first, and the run-as user switches to them.

Then, in your record-triggered flow, add the **Enrich with Amplemarket (Async, No User Permissions)** Apex action and pass the record Id. Leave the reveal inputs blank to use your Settings defaults, or set them to override per run.

Results appear on the **Enrichment Log**; each queued item is tracked on the **Enrichment Request** object (`Pending` → `Processing` → `Complete`/`Failed`).

## 5. Verify

- Open a Lead with a real corporate email, click **Enrich with Amplemarket**, walk through the screen flow, confirm: mapped output fields are populated and an `Enrichment_Log__c` row exists with `Status = Success`.
- Run `sf apex run-test --test-level RunLocalTests --code-coverage --result-format human --target-org <yourOrg>` and verify ≥ 85% coverage and all green.

## Troubleshooting

| Symptom | Likely cause |
| --- | --- |
| `INVALID_SESSION_ID` or 401 on callout | Token not set on the External Credential principal, or principal not enabled on the assigned permission set |
| `No active match-input mappings configured for X` log | The Settings tab has no `Match Input` rows for that object yet |
| Output fields don't update | The `Output Field` mapping is inactive, the Salesforce field is read-only/formula, or the response did not contain that path |
| LWC says *Read-only* | The user lacks the `Manage_Amplemarket_Settings` custom permission (granted via Amplemarket Admin perm set) |
| Async requests stay *Pending* | Automated enrichment is switched off, or its scheduled jobs were aborted. Re-save on the Credit Tracking tab |
| Enrichment Requests end as *Failed* with an external-credential error | The run-as user lacks the Amplemarket perm set / External Credential access. Have an admin who has it re-save Automated Enrichment |
| Apex deployment fails with *…deployments with Apex jobs* | The digest or automation jobs are scheduled. Turn them off before deploying, or enable "Allow deployments of components when corresponding Apex jobs are pending" in Setup → Deployment Settings |
