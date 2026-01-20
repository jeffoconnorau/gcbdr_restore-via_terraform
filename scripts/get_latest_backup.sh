#!/bin/bash
set -e

# Read JSON from stdin
eval "$(jq -r '@sh "PROJECT=\(.project) LOCATION=\(.location) INSTANCE_NAME=\(.instance_name) VAULT_ID=\(.vault_id) VAULT_PROJECT=\(.vault_project)"')"

# Default VAULT_PROJECT to PROJECT if not set
if [[ -z "$VAULT_PROJECT" || "$VAULT_PROJECT" == "null" ]]; then
  VAULT_PROJECT="$PROJECT"
fi

# Validate inputs
if [[ -z "$PROJECT" || -z "$LOCATION" || -z "$INSTANCE_NAME" || -z "$VAULT_ID" ]]; then
  echo '{"error": "Missing required input variables"}' >&2
  exit 1
fi

echo "[INFO] Starting dynamic backup discovery for instance: $INSTANCE_NAME" >&2
echo "[INFO] Project: $PROJECT, Location: $LOCATION, Vault: $VAULT_ID, Vault Project: $VAULT_PROJECT" >&2

# 1. List all data sources and filter with jq (more robust than gcloud filter for complex objects)
# Fetch JSON list of all data sources in the vault
echo "[INFO] Fetching list of all Data Sources in the Vault..." >&2
ALL_DATASOURCES_JSON=$(gcloud backup-dr data-sources list \
  --project="$VAULT_PROJECT" \
  --location="$LOCATION" \
  --backup-vault="$VAULT_ID" \
  --format="json")

DS_COUNT=$(echo "$ALL_DATASOURCES_JSON" | jq length)
echo "[INFO] Found $DS_COUNT total Data Sources. Searching for one matching '$INSTANCE_NAME'..." >&2

# Resolve Disk ID if proper name match is not guaranteed by simple string
DISK_ID=""
# We attempt to look up the disk ID if the name suggests a disk or just try anyway
if [[ "$INSTANCE_NAME" == *"disk"* ]]; then
  echo "[INFO] Attempting to resolve Disk ID for '$INSTANCE_NAME'..." >&2
  # Try to find disk ID in the same region (zones a,b,c)
  for zone_suffix in "a" "b" "c"; do
      ZONE="${LOCATION}-${zone_suffix}"
      FOUND_ID=$(gcloud compute disks describe "$INSTANCE_NAME" --project="$PROJECT" --zone="$ZONE" --format="value(id)" 2>/dev/null || true)
      if [ ! -z "$FOUND_ID" ]; then
        DISK_ID="$FOUND_ID"
        echo "[INFO] Resolved Disk Name '$INSTANCE_NAME' to ID '$DISK_ID'" >&2
        break
      fi
  done
fi

# Filter for the instance name using jq
# Check known paths for Instance (name), SQL (name), and Disks (gcpResourcename with ID)
DATASOURCE_ID=$(echo "$ALL_DATASOURCES_JSON" | jq -r --arg NAME "$INSTANCE_NAME" --arg DISK_ID "$DISK_ID" '
  .[] | select(
    (.dataSourceGcpResource.computeInstanceDatasourceProperties.name // "" | endswith("/" + $NAME)) or
    (.dataSourceGcpResource.cloudSqlInstanceDatasourceProperties.name // "" | endswith("/" + $NAME)) or
    (.dataSourceGcpResource.computeDiskDatasourceProperties.name // "" | endswith("/" + $NAME)) or
    ($DISK_ID != "" and (.dataSourceGcpResource.gcpResourcename // "" | endswith("/disks/" + $DISK_ID))) or
    (.name | contains($NAME))
  ) | .name' | head -n 1)

if [[ -z "$DATASOURCE_ID" || "$DATASOURCE_ID" == "null" ]]; then
  echo "[ERROR] Data source NOT FOUND for instance $INSTANCE_NAME" >&2
  echo "{\"error\": \"Data source not found for instance $INSTANCE_NAME\"}" >&2
  exit 1
fi

echo "[INFO] Identified Data Source ID: $DATASOURCE_ID" >&2

# 2. Find Latest Backup for the Data Source
# Filter keys like 'dataSource' are not reliable in gcloud list output for this resource.
# Fetching all backups in the vault and filtering client-side.
echo "[INFO] Fetching list of all Backups in the region..." >&2
ALL_BACKUPS_JSON=$(gcloud backup-dr backups list \
  --project="$VAULT_PROJECT" \
  --location="$LOCATION" \
  --format="json")

BACKUP_COUNT=$(echo "$ALL_BACKUPS_JSON" | jq length)
echo "[INFO] Found $BACKUP_COUNT total Backups. Filtering for Data Source..." >&2

# Filter for backups belonging to the datasource and pick latest (sort by createTime desc)
BACKUP_ID=$(echo "$ALL_BACKUPS_JSON" | jq -r --arg DS_ID "$DATASOURCE_ID" '
  map(select(.name | startswith($DS_ID + "/backups/")))
  | sort_by(.createTime) | reverse | .[0].name // ""
')

if [[ -z "$BACKUP_ID" || "$BACKUP_ID" == "null" ]]; then
  echo "[ERROR] No backups found for Data Source $DATASOURCE_ID" >&2
  echo "{\"error\": \"No backups found for data source $DATASOURCE_ID\"}" >&2
  exit 1
fi

echo "[INFO] Selected Latest Backup ID: $BACKUP_ID" >&2

echo "[INFO] Selected Latest Backup ID: $BACKUP_ID" >&2

# Parse components from the full Backup ID
# Format: projects/{project}/locations/{location}/backupVaults/{vault}/dataSources/{datasource}/backups/{backup}
SHORT_BACKUP_ID=$(echo "$BACKUP_ID" | sed -E 's/.*backups\///')
DATASOURCE_ID_SHORT=$(echo "$DATASOURCE_ID" | sed -E 's/.*dataSources\///')

# Output JSON with all required components for the Terraform resource
jq -n \
  --arg backup_id "$SHORT_BACKUP_ID" \
  --arg backup_vault_id "$VAULT_ID" \
  --arg data_source_id "$DATASOURCE_ID_SHORT" \
  --arg location "$LOCATION" \
  --arg full_backup_id "$BACKUP_ID" \
  '{
    "backup_id": $backup_id,
    "backup_vault_id": $backup_vault_id,
    "data_source_id": $data_source_id,
    "location": $location,
    "full_backup_id": $full_backup_id
  }'
