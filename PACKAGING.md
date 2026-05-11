# Packaging

This project is configured as a **2GP managed package** with namespace `ample` and package alias `Amplemarket Enrichment`. Source-of-truth lives in this repo; package versions are built via the Salesforce CLI against your Dev Hub.

## Prerequisites (one-time)

1. **Dev Hub org** with 2GP packaging enabled.
2. **Developer Edition org** with the namespace `ample` registered (Setup → Package Manager → Edit → Namespace Prefix).
3. **Link the DE org to the Dev Hub** as a namespace org:
   - In the DE org: Setup → Dev Hub → enable Dev Hub features (or just authorize from CLI as below).
   - From CLI:
     ```bash
     sf org login web --alias ample-namespace --instance-url https://login.salesforce.com
     ```
   - Then in your Dev Hub: Setup → **Namespace Registries** → **Link Namespace** → select `ample-namespace`.
4. **Authorize your Dev Hub** with the CLI (if not already):
   ```bash
   sf org login web --alias amplemarket-devhub --set-default-dev-hub
   ```

## First-time package creation

You only run this once per package. It assigns the package an ID (`0Ho...`) and writes it into `sfdx-project.json` under `packageAliases`.

```bash
sf package create \
  --name "Amplemarket Enrichment" \
  --description "Amplemarket data enrichment for Lead, Contact, and Account." \
  --package-type Managed \
  --path force-app \
  --target-dev-hub amplemarket-devhub
```

After this runs, commit the updated `sfdx-project.json`.

## Build a new package version

```bash
sf package version create \
  --package "Amplemarket Enrichment" \
  --installation-key-bypass \
  --code-coverage \
  --wait 30 \
  --target-dev-hub amplemarket-devhub
```

This produces a **beta** version (e.g. `04t...`). Beta versions can be installed in test orgs but cannot be promoted/distributed to production-style installs. Each new version increments the `NEXT` token in `sfdx-project.json`'s `versionNumber`.

Install the beta in a test org:

```bash
sf package install --package 04t... --target-org <yourTestOrg> --wait 10
```

## Promote a version to released

Once you've verified the beta in a test org and you're happy with the version, promote it. **Promotion is irreversible** — once a version is released, you cannot remove components from it or downgrade/republish that version.

```bash
sf package version promote --package 04t... --target-dev-hub amplemarket-devhub
```

Released versions can be installed in production orgs and listed on AppExchange.

## Versioning

`sfdx-project.json` controls version metadata via `versionName`, `versionNumber`, and `versionDescription` under the `packageDirectories` entry. After releasing a version, bump `versionNumber` (e.g. `0.1.0.NEXT` → `0.2.0.NEXT`) and update `versionName` for the next build.

## What changes in a packaged install

Once installed in a subscriber org, every component this package owns will be prefixed with `ample__`:

- Custom objects: `ample__Amplemarket_Mapping__c`, `ample__Enrichment_Log__c`, `ample__Enrichment_Log_Field__c`
- Custom fields on those objects (e.g. `ample__Salesforce_Field__c`)
- Custom permissions: `ample__Manage_Amplemarket_Settings`, `ample__Run_Amplemarket_Enrichment`
- Apex classes: `ample.AmplemarketEnrichInvocable`, etc.
- Custom tabs, flows, quick actions, named credentials, content asset, application

In-package source references (Apex calling Apex, flow calling Apex, LWC importing Apex) work without the prefix at compile time — Salesforce auto-resolves them. Subscribers calling the package from their own code must use the `ample__` prefix.

## Things to watch when iterating

- Once a version is **promoted**, you cannot remove or rename most components. Plan removals before promoting.
- Custom field types, picklist values (in restricted picklists), and other backing-store decisions are sticky after release. The first promoted version locks the schema floor.
- Test classes count toward the ≥75% Apex coverage requirement at version-create time. Make sure tests pass via `sf apex run-test --test-level RunLocalTests` before building a version.
- The `manifest/package.xml` in this repo is for ad-hoc deploys; it's not used by packaging.
