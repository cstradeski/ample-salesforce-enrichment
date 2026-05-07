# Post-deploy steps

After deploying this package to a sandbox or production org, complete the following.

## 1. Configure the External Credential principal + auth header

The metadata deploys an empty `Amplemarket_External` external credential and an `Amplemarket_API` named credential pointing at `https://api.amplemarket.com`. You finish the auth wiring in Setup so the bearer token is never committed to source control.

### 1a. External Credential — add the principal and auth header

1. Setup → **Named Credentials** → tab **External Credentials** → open **Amplemarket External**
2. **Principals** → **New**
   - Parameter Name: `AmplemarketBearer`
   - Identity Type: `Named Principal`
   - Sequence Number: `1`
   - Authentication Parameters → **New** → Name `Token`, Value `<your Amplemarket API key>`
   - Save
3. **Custom Headers** → **New**
   - Name: `Authorization`
   - Value: `Bearer {!$Credential.Amplemarket_External.Token}`
   - Sequence Number: `1`
   - Save

### 1b. Permission Set mappings

In each Permission Set (**Amplemarket Admin** and **Amplemarket User**), enable access to the principal:

1. Setup → **Permission Sets** → open the perm set
2. **External Credential Principal Access** → **Edit** → enable `Amplemarket External - AmplemarketBearer`
3. Save

The Named Credential will now inject the `Authorization: Bearer …` header automatically on every Apex callout — no code change needed. To rotate, just edit the `Token` parameter value.

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
