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
