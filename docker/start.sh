#!/bin/bash
set -e
set -o pipefail

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

AZP_POOL="${AZP_POOL:-Default}"
AZP_WORK="${AZP_WORK:-_work}"
AZP_AGENT_ONCE="${AZP_AGENT_ONCE:-false}"

mkdir -p "$AZP_WORK"

rm -rf /azp/agent
mkdir -p /azp/agent
cd /azp/agent

export AGENT_ALLOW_RUNASROOT="1"

cleanup() {
  if [ -e config.sh ]; then
    print_header "Cleanup. Removing Azure Pipelines agent..."

    ./config.sh remove --unattended \
      --auth PAT \
      --token "$(cat "$AZP_TOKEN_FILE")"
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

REPO="microsoft/azure-pipelines-agent"

CPU_ARCH="$(uname -m)"
case "$CPU_ARCH" in
  aarch64|arm64)
    ARCH="linux-arm64"
    ;;
  armv7l|armv6l)
    ARCH="linux-arm"
    ;;
  x86_64|amd64)
    ARCH="linux-x64"
    ;;
  *)
    ARCH="linux-x64"
    ;;
esac

# Detect musl (e.g., Alpine) and switch to musl packages if available
if [ -f /etc/alpine-release ]; then
  case "$ARCH" in
    linux-x64) ARCH="linux-musl-x64" ;;
    linux-arm64) ARCH="linux-musl-arm64" ;;
  esac
fi

RELEASE_JSON=$(curl -s "https://api.github.com/repos/$REPO/releases/latest")
VERSION=$(echo "$RELEASE_JSON" | jq -r '.tag_name')

VERSION="${VERSION#v}"

if [ -z "$VERSION" ] || [ "$VERSION" == "null" ]; then
  echo 1>&2 "error: could not determine a matching Azure Pipelines agent version from GitHub releases"
  exit 1
fi

BASE_URL="https://download.agent.dev.azure.com/agent/$VERSION"
FILE="vsts-agent-$ARCH-$VERSION.tar.gz"
AZP_AGENTPACKAGE_URL="$BASE_URL/$FILE"
CHECKSUM_URL=$(echo "$RELEASE_JSON" | jq -r --arg file "$FILE" '[.assets[]? | select(.name == ($file + ".sha256") or .name == ($file + ".sha256sum") or .name == ($file + ".sha256.txt")) | .browser_download_url][0] // empty')

print_header "2. Downloading and installing Azure Pipelines agent..."

curl -LsS "$AZP_AGENTPACKAGE_URL" | tar -xz

if [ -n "$CHECKSUM_URL" ]; then
  print_header "2b. Verifying package checksum..."
  if command -v sha256sum >/dev/null 2>&1; then
    CHECKSUM_VALUE=$(curl -sS "$CHECKSUM_URL" | awk '{print $1}')
    if [ -z "$CHECKSUM_VALUE" ]; then
      echo 1>&2 "error: checksum file was empty"
      exit 1
    fi
    echo "$CHECKSUM_VALUE  $FILE" | sha256sum -c -
  else
    echo 1>&2 "warning: sha256sum not available; skipping checksum verification"
  fi
else
  echo 1>&2 "warning: no checksum asset found in GitHub release; skipping verification"
fi

source ./env.sh

trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

print_header "3. Configuring Azure Pipelines agent..."

echo "Debug: uname -m = $(uname -m)"
echo "Debug: uname -s = $(uname -s)"
echo "Debug: OS release = $(cat /etc/os-release 2>/dev/null | tr '\n' ' ')"
echo "Debug: Selected ARCH = $ARCH"
echo "Debug: Agent.Listener file info:"
if command -v file >/dev/null 2>&1; then
  file ./bin/Agent.Listener || true
else
  echo "Debug: 'file' not installed"
fi
echo "Debug: Agent.Listener ldd output (if available):"
if command -v ldd >/dev/null 2>&1; then
  ldd ./bin/Agent.Listener 2>/dev/null || true
else
  echo "Debug: 'ldd' not installed"
fi

./config.sh --unattended \
  --agent "${AZP_AGENT_NAME:-$(hostname)}" \
  --url "$AZP_URL" \
  --auth PAT \
  --token "$(cat "$AZP_TOKEN_FILE")" \
  --pool "${AZP_POOL:-Default}" \
  --work "${AZP_WORK:-_work}" \
  --once "${AZP_AGENT_ONCE}" \
  --replace \
  --acceptTeeEula & wait $!

# remove the administrative token before accepting work
rm -f "$AZP_TOKEN_FILE"

print_header "4. Running Azure Pipelines agent..."

# `exec` the node runtime so it's aware of TERM and INT signals
# AgentService.js understands how to handle agent self-update and restart
exec ./externals/node/bin/node ./bin/AgentService.js interactive
