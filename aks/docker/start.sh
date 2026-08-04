#!/bin/bash
set -e

if [ -z "$AZP_URL" ]; then
  echo 1>&2 "error: missing AZP_URL environment variable"
  exit 1
fi

if [ -z "$AZP_TOKEN_FILE" ]; then
  AZP_TOKEN_FILE=./token

  if [ -z "$AZP_TOKEN" ]; then
    # No PAT provided; try to acquire a token from Azure Managed Identity (IMDS).
    # Set AZP_CLIENT_ID to a user-assigned managed identity client ID if needed.
    echo "AZP_TOKEN not set; attempting to acquire token via Azure Managed Identity (IMDS)..."

    IMDS_URL="http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=499b84ac-1321-427f-aa17-267ca6975798"

    if [ -n "$AZP_CLIENT_ID" ]; then
      ENCODED_CLIENT_ID=$(printf '%s' "$AZP_CLIENT_ID" | sed 's/ /%20/g')
      IMDS_URL="${IMDS_URL}&client_id=${ENCODED_CLIENT_ID}"
    fi

    MI_TOKEN_RESPONSE=$(curl -sS --max-time 10 \
      -H "Metadata: true" \
      "$IMDS_URL" 2>/dev/null) || true

    if ! echo "$MI_TOKEN_RESPONSE" | jq -e '.access_token' >/dev/null 2>&1; then
      echo 1>&2 "error: AZP_TOKEN is not set and the managed identity IMDS endpoint is unavailable or returned no token."
      echo 1>&2 "  To use a PAT, set the AZP_TOKEN environment variable."
      echo 1>&2 "  To use managed identity, ensure the container runs on an Azure resource with an assigned identity"
      echo 1>&2 "  and that the identity has been added to the Azure DevOps organization/project."
      exit 1
    fi

    AZP_TOKEN=$(echo "$MI_TOKEN_RESPONSE" | jq -r '.access_token')
    echo "Managed identity token acquired successfully."
  fi

  echo -n "$AZP_TOKEN" > "$AZP_TOKEN_FILE"
fi

unset AZP_TOKEN

if [ -n "$AZP_WORK" ]; then
  mkdir -p "$AZP_WORK"
fi

export AGENT_ALLOW_RUNASROOT="0"

cleanup() {
  if [ -e config.sh ]; then
    print_header "Cleanup. Removing Azure Pipelines agent..."

    # If the agent has some running jobs, the configuration removal process will fail.
    # So, give it some time to finish the job.
    while true; do
      ./config.sh remove --unattended --auth PAT --token $(cat "$AZP_TOKEN_FILE") && break

      echo "Retrying in 30 seconds..."
      sleep 30
    done
  fi
}

print_header() {
  lightcyan='\033[1;36m'
  nocolor='\033[0m'
  echo -e "${lightcyan}$1${nocolor}"
}

# Let the agent ignore the token env variables
export VSO_AGENT_IGNORE=AZP_TOKEN,AZP_TOKEN_FILE

print_header "1. Determining matching Azure Pipelines agent..."

AZP_AGENT_PACKAGES=$(curl -LsS \
    -u user:$(cat "$AZP_TOKEN_FILE") \
    -H 'Accept:application/json;' \
    "$AZP_URL/_apis/distributedtask/packages/agent?platform=$TARGETARCH&top=1")

AZP_AGENT_PACKAGE_LATEST_URL=$(echo "$AZP_AGENT_PACKAGES" | jq -r '.value[0].downloadUrl')

if [ -z "$AZP_AGENT_PACKAGE_LATEST_URL" -o "$AZP_AGENT_PACKAGE_LATEST_URL" == "null" ]; then
  echo 1>&2 "error: could not determine a matching Azure Pipelines agent"
  echo 1>&2 "check that account '$AZP_URL' is correct and the token is valid for that account"
  exit 1
fi

print_header "2. Downloading and extracting Azure Pipelines agent..."

curl -LsS $AZP_AGENT_PACKAGE_LATEST_URL | tar -xz --no-overwrite-dir & wait $!

source ./env.sh

print_header "3. Configuring Azure Pipelines agent..."

./config.sh --unattended \
  --agent "${AZP_AGENT_NAME:-$(hostname)}" \
  --url "$AZP_URL" \
  --auth PAT \
  --token $(cat "$AZP_TOKEN_FILE") \
  --pool "${AZP_POOL:-Default}" \
  --work "${AZP_WORK:-_work}" \
  --replace \
  --acceptTeeEula & wait $!

print_header "4. Running Azure Pipelines agent..."

trap 'cleanup; exit 0' EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

chmod +x ./run-docker.sh

# To be aware of TERM and INT signals call run.sh
# Running it with the --once flag at the end will shut down the agent after the build is executed
./run-docker.sh "$@" & wait $!