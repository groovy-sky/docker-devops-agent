#!/bin/bash
set -e

if [ -z "$AZP_URL" ]; then
  echo 1>&2 "error: missing AZP_URL environment variable"
  exit 1
fi

if [ -z "$AZP_TOKEN_FILE" ]; then
  AZP_TOKEN_FILE="/azp/.token"
fi

if [ -z "$AZP_TOKEN" ]; then
  # Attempt managed identity token retrieval to validate IMDS availability
  MI_TOKEN_RESPONSE=$(curl -sS \
    -H "Metadata: true" \
    "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=499b84ac-1321-427f-aa17-267ca6975798") || true

  if ! echo "$MI_TOKEN_RESPONSE" | jq -e '.access_token' >/dev/null 2>&1; then
    echo 1>&2 "error: missing AZP_TOKEN environment variable and managed identity endpoint is not available"
    exit 1
  fi

  AZP_TOKEN=$(echo "$MI_TOKEN_RESPONSE" | jq -r '.access_token')
fi

echo -n "$AZP_TOKEN" > "$AZP_TOKEN_FILE"

unset AZP_TOKEN

if [ -n "$AZP_WORK" ]; then
  mkdir -p "$AZP_WORK"
fi

rm -rf /azp/agent
mkdir /azp/agent
cd /azp/agent

export AGENT_ALLOW_RUNASROOT="1"

cleanup() {
  if [ -e config.sh ]; then
    print_header "Cleanup. Removing Azure Pipelines agent..."

    ./config.sh remove --unattended \
      --auth PAT \
      --token $(cat "$AZP_TOKEN_FILE")
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

ARCH=$(uname -m)
case "$ARCH" in
  x86_64) AZP_PLATFORM="linux-x64" ;;
  aarch64|arm64) AZP_PLATFORM="linux-arm64" ;;
  armv7l|armv6l) AZP_PLATFORM="linux-arm" ;;
  *) AZP_PLATFORM="linux-x64" ;;
esac

AZP_AGENT_RESPONSE=$(curl -LsS \
  -u user:$(cat "$AZP_TOKEN_FILE") \
  -H 'Accept:application/json;api-version=3.0-preview' \
  "$AZP_URL/_apis/distributedtask/packages/agent?platform=${AZP_PLATFORM}")

if ! echo "$AZP_AGENT_RESPONSE" | jq . >/dev/null 2>&1; then
  echo 1>&2 "error: invalid response from Azure DevOps when requesting agent packages"
  echo 1>&2 "$AZP_AGENT_RESPONSE"
  exit 1
fi

if ! echo "$AZP_AGENT_RESPONSE" | jq -e '.value and (.value | length > 0)' >/dev/null 2>&1; then
  echo 1>&2 "error: no agent packages returned for platform '${AZP_PLATFORM}'"
  echo 1>&2 "$AZP_AGENT_RESPONSE"
  exit 1
fi

AZP_AGENTPACKAGE_URL=$(echo "$AZP_AGENT_RESPONSE" \
  | jq -r '.value | map([.version.major,.version.minor,.version.patch,.downloadUrl]) | sort | .[length-1] | .[3]')

if [ -z "$AZP_AGENTPACKAGE_URL" -o "$AZP_AGENTPACKAGE_URL" == "null" ]; then
  echo 1>&2 "error: could not determine a matching Azure Pipelines agent - check that account '$AZP_URL' is correct and the token is valid for that account"
  exit 1
fi

print_header "2. Downloading and installing Azure Pipelines agent..."

curl -LsS $AZP_AGENTPACKAGE_URL | tar -xz & wait $!

source ./env.sh

trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

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

# remove the administrative token before accepting work
rm $AZP_TOKEN_FILE

print_header "4. Running Azure Pipelines agent..."

# `exec` the node runtime so it's aware of TERM and INT signals
# AgentService.js understands how to handle agent self-update and restart
exec ./externals/node/bin/node ./bin/AgentService.js interactive
