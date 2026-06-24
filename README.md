# Big Object Tooling (BIGOTOOL)

A Salesforce admin toolkit for **archiving records** and **logging field history** into **Big Objects** — all configured with point-and-click LWC wizards. It auto-generates the archive Big Object, its viewer page, tab and access permission set for you, so you don't hand-write any metadata.

> Full design details are in [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## What it does

- **Field History Logging** — Track old/new values of any fields on any object, beyond the native 20-field / 18-month limit. All history lands in one shared `FieldChangeLog__b` Big Object and is shown on any record page via a timeline component.
- **Data Archival** — Move aged or filter-matched records out of a source object into a generated `Archive_<Object>__b` Big Object (with optional delete-after-archive), on a schedule.
- **Data Restore** — Rehydrate a single archived record back into the source (or a target) object using a configurable restore profile.
- **CSV Export** — Export archived rows (up to 50,000) to CSV, gated by a dedicated permission.
- **Dashboard** — Monitor config coverage, job runs and flip global on/off toggles.

### Key building blocks

| Area           | Component                                                                                                      |
| -------------- | -------------------------------------------------------------------------------------------------------------- |
| Wizards        | `bigotoolArchiveWizard`, `bigotoolFieldLogWizard`                                                              |
| Viewers        | `bigotoolHistoryTimeline`, `bigotoolArchiveListView`, `bigotoolArchiveRecordView`, `bigotoolDashboard`         |
| Config objects | `Archive_Config__c` (+`Archive_Field__c`, `Restore_Profile__c`), `Field_Log_Config__c` (+`Field_Log_Field__c`) |
| Settings       | `BIGOTOOL_Settings__c` (hierarchy custom setting)                                                              |
| Generation     | `BIGOTOOL_GenerationController` → `BIGOTOOL_MetadataGenerator` → `MetadataService`                             |

## Prerequisites

- **Salesforce CLI** — [install guide](https://developer.salesforce.com/docs/atlas.en-us.sfdx_setup.meta/sfdx_setup/sfdx_setup_install_cli.htm)
- A target org (sandbox, scratch, or developer org) with **My Domain** enabled
- Node.js (only if you want to run the LWC unit tests / linting)

## Deploy to an org

The whole package lives in `force-app/` and deploys with the Salesforce CLI.

```bash
# 1. Authorize your org (gives it the alias "bigotool")
sf org login web --alias bigotool --set-default

# 2. Deploy all metadata
sf project deploy start --source-dir force-app --target-org bigotool

# 3. Assign a permission set to yourself (admins get full access)
sf org assign permset --name BIGOTOOL_Administrator --target-org bigotool

# 4. Open the org
sf org open --target-org bigotool
```

> **Scratch org alternative:** `sf org create scratch --definition-file config/project-scratch-def.json --alias bigotool --set-default`, then run steps 2–4.

### Permission sets

Assign per persona:

| Permission Set            | Grants                                                  |
| ------------------------- | ------------------------------------------------------- |
| `BIGOTOOL_Administrator`  | Everything (configure, generate, view, restore, export) |
| `BIGOTOOL_Configurator`   | Create/manage configs and run generation                |
| `BIGOTOOL_Archive_Viewer` | Read archived data (plus the generated per-object set)  |
| `BIGOTOOL_History_Viewer` | Read field-change history                               |
| `BIGOTOOL_Data_Exporter`  | Add-on for CSV export                                   |

## How to use the package

Open the **Big Object Tooling** Lightning app from the App Launcher.

### Archive an object

1. Go to the **Archive Configurations** tab → **New**, or open the **Archive Wizard**.
2. Pick the source object, define **age and/or SOQL criteria**, choose which fields show as list-view columns, set a **schedule** (CRON) and a **restore profile**, then review.
3. Open the saved config and click **Generate**. This creates the `Archive_<Object>__b` Big Object, a Lightning page + tab to browse it, and a permission set granting access.
4. The scheduled **archive batch** runs per your CRON (or use **Run now** on the scheduler component). Browse results from the generated tab; open a row to **view** or **Restore** it; use **Export** for CSV.

### Log field history

1. Open the **Field Log Wizard** → choose an object, select the fields to track (flag PII fields to mask), pick the events (create/update/delete/undelete) and the async mode (**Platform Event** recommended), set retention, and save.
2. Use the **Generate Trigger Code** component on the config to copy the generated trigger, then **deploy that trigger** on the source object (this step is manual by design).
3. Drop the **History Timeline** component onto any record page to see the change history.

### Global toggles

Use the **Dashboard** to monitor jobs and flip org-wide switches — `Master_Switch__c` (kill switch), `Logging_Enabled__c`, `Archiving_Enabled__c` — stored in `BIGOTOOL_Settings__c`.



Apex tests deploy with the package; run them with `sf apex run test --target-org bigotool`.

## Notes & limits

- The generation engine self-calls the **Metadata API**, so the `BIGOTOOL_Metadata_API` Remote Site Setting **must** match your org's My Domain (see deploy step 2).
- Big Objects are queried **left-to-right on their index**, are **immutable** (re-insert = overwrite) and **eventually consistent**.
- CSV export is **synchronous** and capped at **50,000 rows**.
- Generated metadata (archive Big Objects, tabs, per-object permission sets) is created at runtime and is **not** checked into this repo.
