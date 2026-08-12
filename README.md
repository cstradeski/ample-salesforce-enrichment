# ample-salesforce-enrichment

Salesforce DX project that enriches **Lead, Contact, and Account** records via the
[Amplemarket Data Enrichment API](https://docs.amplemarket.com/api-reference/introduction).

## What's in here

| Component | Purpose |
| --- | --- |
| `AmplemarketEnrichInvocable` | `@InvocableMethod` callable from screen flows; supports single (sync) and bulk (async via Queueable) modes |
| `AmplemarketEnrichAsyncInvocable` | Second flow action for automated flows: publishes a platform event so the callout runs as a nominated integration user, and the triggering user needs no Amplemarket permissions |
| `AmplemarketEnrichmentService` | Reads field mappings, calls `/people/find` or `/companies/find`, writes results back, logs every call |
| `AmplemarketHttpClient` | Wrapper over `Http` that uses the `Amplemarket_API` Named Credential |
| `Amplemarket_Mapping__c` | Custom object holding match-input + output-field mappings, per object — saved with regular DML from the LWC |
| `Enrichment_Log__c` | Audit log of every enrichment call |
| `amplemarketSettings` LWC | Admin-facing UI for configuring mappings; saves via the Apex Metadata API |
| `Enrich_*` flows + quick actions | Record-page **Enrich with Amplemarket** action for Lead, Contact, Account |
| `Amplemarket_Admin` / `Amplemarket_User` permission sets | Admin vs end-user access |

## Distribution model

This is a **2GP managed package** with namespace `ample`. End users receive it as a package install (a `04t...` URL or AppExchange listing); they do not deploy source. See [PACKAGING.md](PACKAGING.md) for the build, version, and promote workflow.

## Install (subscriber orgs)

```bash
sf package install --package 04t... --target-org <yourOrg> --wait 10
```

Then follow [POST_DEPLOY.md](POST_DEPLOY.md) to set your API token, assign permission sets, and configure record-page actions.

## Source deploy (development only)

For development against a scratch/sandbox without going through packaging:

```bash
sf project deploy start --source-dir force-app --target-org <yourOrg>
```

## Test

```bash
sf apex run-test --test-level RunLocalTests --code-coverage --result-format human --target-org <yourOrg>
```
