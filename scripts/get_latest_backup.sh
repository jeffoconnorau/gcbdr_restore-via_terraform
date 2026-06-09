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

# Initialize debug log immediately so it is guaranteed to exist
echo "=== Starting Discovery Run $(date) ===" > debug_discovery.log
echo "Querying DataSources: Project=$VAULT_PROJECT, Location=$LOCATION, Vault=$VAULT_ID, Instance=$INSTANCE_NAME" >> debug_discovery.log

echo "[INFO] Fetching list of all Data Sources in the Vault..." >&2
ALL_DATASOURCES_JSON=$(gcloud backup-dr data-sources list \
  --project="$VAULT_PROJECT" \
  --location="$LOCATION" \
  --backup-vault="$VAULT_ID" \
  --format="json" 2>> debug_discovery.log) || true

echo "DataSources JSON returned length: ${#ALL_DATASOURCES_JSON}" >> debug_discovery.log

if [[ -z "$ALL_DATASOURCES_JSON" || "$ALL_DATASOURCES_JSON" == "null" || "$ALL_DATASOURCES_JSON" == "[]" ]]; then
  echo "[WARNING] Vault empty, not found, or gcloud failed. Check debug_discovery.log for details." >&2
  echo "Result: Vault empty or gcloud failed" >> debug_discovery.log
  echo '{"backup_id": "dummy", "backup_vault_id": "dummy", "data_source_id": "dummy", "location": "dummy", "full_backup_id": "dummy"}'
  exit 0
fi

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

# Log matching candidates to debug file before backupCount filter
echo "$ALL_DATASOURCES_JSON" | jq -r --arg NAME "$INSTANCE_NAME" --arg DISK_ID "$DISK_ID" '
  map(select(
    (.dataSourceGcpResource.computeInstanceDatasourceProperties.name // "" | endswith("/" + $NAME)) or
    (.dataSourceGcpResource.cloudSqlInstanceDatasourceProperties.name // "" | endswith("/" + $NAME)) or
    (.dataSourceGcpResource.computeDiskDatasourceProperties.name // "" | endswith("/" + $NAME)) or
    (.dataSourceGcpResource.gcpResourcename // "" | endswith("/" + $NAME)) or
    (.dataSourceGcpResource.gcpResourcename // "" | endswith("/instances/" + $NAME)) or
    (.dataSourceGcpResource.gcpResourcename // "" | endswith("/clusters/" + $NAME)) or
    ($DISK_ID != "" and (.dataSourceGcpResource.gcpResourcename // "" | endswith("/disks/" + $DISK_ID))) or
    (.name | contains($NAME))
  )) | "Candidate DataSources for \($NAME): \(map({name: .name, backupCount: .backupCount}))"
' >> debug_discovery.log 2>/dev/null || true

DATASOURCE_ID=$(echo "$ALL_DATASOURCES_JSON" | jq -r --arg NAME "$INSTANCE_NAME" --arg DISK_ID "$DISK_ID" '
  map(select(
    (.dataSourceGcpResource.computeInstanceDatasourceProperties.name // "" | endswith("/" + $NAME)) or
    (.dataSourceGcpResource.cloudSqlInstanceDatasourceProperties.name // "" | endswith("/" + $NAME)) or
    (.dataSourceGcpResource.computeDiskDatasourceProperties.name // "" | endswith("/" + $NAME)) or
    (.dataSourceGcpResource.gcpResourcename // "" | endswith("/" + $NAME)) or
    (.dataSourceGcpResource.gcpResourcename // "" | endswith("/instances/" + $NAME)) or
    (.dataSourceGcpResource.gcpResourcename // "" | endswith("/clusters/" + $NAME)) or
    ($DISK_ID != "" and (.dataSourceGcpResource.gcpResourcename // "" | endswith("/disks/" + $DISK_ID))) or
    (.name | contains($NAME))
  ))
  | map(select((.backupCount // "0" | tonumber) > 0))
  | sort_by(.createTime) | reverse | .[0].name // ""
')

if [[ -z "$DATASOURCE_ID" || "$DATASOURCE_ID" == "null" ]]; then
  echo "[WARNING] Data source NOT FOUND (or has 0 backups) for instance $INSTANCE_NAME. Returning dummy data." >&2
  echo "Result: DataSource NOT FOUND or backupCount == 0" >> debug_discovery.log
  echo '{"backup_id": "dummy", "backup_vault_id": "dummy", "data_source_id": "dummy", "location": "dummy", "full_backup_id": "dummy"}'
  exit 0
fi

echo "[INFO] Identified Data Source ID: $DATASOURCE_ID" >&2

# 2. Find Latest Backup for the Data Source
DATASOURCE_ID_SHORT=$(echo "$DATASOURCE_ID" | sed -E 's/.*dataSources\///')
echo "[INFO] Fetching Backups for DataSource $DATASOURCE_ID_SHORT..." >&2

ALL_BACKUPS_JSON=$(gcloud backup-dr backups list \
  --project="$VAULT_PROJECT" \
  --location="$LOCATION" \
  --backup-vault="$VAULT_ID" \
  --data-source="$DATASOURCE_ID_SHORT" \
  --format="json" 2>> debug_discovery.log) || true

echo "=== Backups Discovery Run $(date) ===" >> debug_discovery.log
echo "Backups JSON returned for $DATASOURCE_ID_SHORT length: ${#ALL_BACKUPS_JSON}" >> debug_discovery.log
echo "$ALL_BACKUPS_JSON" >> debug_discovery.log

BACKUP_ID=$(echo "$ALL_BACKUPS_JSON" | jq -r 'sort_by(.createTime) | reverse | .[0].name // ""' 2>/dev/null || echo "")

if [[ -z "$BACKUP_ID" || "$BACKUP_ID" == "null" || "$BACKUP_ID" == "dummy" ]]; then
  echo "[WARNING] No backups returned for DataSource $DATASOURCE_ID_SHORT. Returning dummy data." >&2
  echo '{"backup_id": "dummy", "backup_vault_id": "dummy", "data_source_id": "dummy", "location": "dummy", "full_backup_id": "dummy"}'
  exit 0
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
