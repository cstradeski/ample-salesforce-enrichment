# Post-deploy steps

After deploying this package to a sandbox or production org, complete the following.

## 1. Set the Amplemarket API token on the External Credential

1. Setup → **Named Credentials** → tab **External Credentials**
2. Open **Amplemarket External**
3. Under **Principals**, edit `AmplemarketBearer`
4. In **Authentication Parameters**, set the parameter named `Token` to your Amplemarket API key (from your Amplemarket dashboard)
5. Save

The Named Credential `Amplemarket_API` will inject the bearer token automatically on every Apex callout — no code change needed.

## 2. Assign permission sets

| Permission set | Who gets it | Grants |
| --- | --- | --- |
| **Amplemarket Admin** | The 1–2 people who manage the configuration | Settings tab + LWC, custom-permission `Manage Amplemarket Settings`, full read/write on `Enrichment_Log__c`, access to the External Credential principal |
| **Amplemarket User** | Anyone who should see the *Enrich with Amplemarket* action on a record | Apex class access to the invocable + service, read/create on `Enrichment_Log__c`, access to the External Credential principal |

```bash
sf org assign permset --name Amplemarket_Admin --target-org <yourOrg>
sf org assign permset --name Amplemarket_User --target-org <yourOrg>
```

## 3. Add the Quick Action to each object's record page

Quick Actions are deployed but not pinned to record-page layouts automatically.

For **Lead**, **Contact**, and **Account**:

1. Setup → Object Manager → choose the object → **Page Layouts**
2. Edit the layout used by your record pages
3. From the palette → **Mobile & Lightning Actions**, drag **Enrich with Amplemarket** into the *Salesforce Mobile and Lightning Experience Actions* section
4. Save

## 4. Configure field mappings

1. App Launcher → **Amplemarket Enrichment** → **Amplemarket Settings** tab
2. For each tab (Lead / Contact / Account):
   - Pick a *Salesforce field* for each *Amplemarket match key* you want to use as input (e.g. Lead.Email → `email`).
   - Toggle **Reveal email** / **Reveal phone** if you want the API to consume reveal credits to return verified contact details.
   - Add **Output Fields** rows: `[Amplemarket field] → [Salesforce field]`. These fields will be written back when enrichment runs.
3. Click **Save**. The deployment runs asynchronously; the page polls and shows the final status.

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
