#!/usr/bin/env bash
set -euo pipefail

SCRIPT_PATH="/home/runner/work/docker-devops-agent/docker-devops-agent/docker/start.sh"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

first_line="$(head -n 1 "$SCRIPT_PATH")"
if [[ "$first_line" == '#!/usr/bin/env bash' ]]; then
  pass "start.sh begins with the raw Bash shebang"
else
  fail "Expected shebang on first line, got: $first_line"
fi

if ! grep -q '^```' "$SCRIPT_PATH"; then
  pass "start.sh does not contain Markdown fences"
else
  fail "start.sh contains unexpected Markdown fences"
fi

if bash -n "$SCRIPT_PATH"; then
  pass "bash -n docker/start.sh succeeds"
else
  fail "bash -n docker/start.sh failed"
fi

select_auth_mode() {
  local imds_response="$1"
  local client_id="${2:-}"
  local pat="${3:-}"
  local auth_mode=""
  local token=""
  local imds_url="http://169.254.169.254/metadata/identity/oauth2/token?api-version=2019-08-01&resource=499b84ac-1321-427f-aa17-267ca6975798"

  if [[ -n "$client_id" ]]; then
    imds_url+="&client_id=${client_id}"
  fi

  if [[ -n "$imds_response" ]]; then
    token="$(jq -r '.access_token // empty' <<<"$imds_response")"
    if [[ -n "$token" ]]; then
      auth_mode="managed_identity"
    fi
  fi

  if [[ -z "$auth_mode" && -n "$pat" ]]; then
    auth_mode="pat"
    token="$pat"
  fi

  if [[ -z "$auth_mode" ]]; then
    return 1
  fi

  printf '%s|%s|%s\n' "$auth_mode" "$token" "$imds_url"
}

result="$(select_auth_mode '{"access_token":"system-mi-token"}' '' 'legacy-pat')"
if [[ "$result" == managed_identity'|'system-mi-token'|'* ]]; then
  pass "managed identity takes precedence when IMDS returns a token"
else
  fail "Expected managed identity precedence, got: $result"
fi

result="$(select_auth_mode '{"access_token":"user-mi-token"}' 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' '')"
if [[ "$result" == *'|http://169.254.169.254/metadata/identity/oauth2/token?api-version=2019-08-01&resource=499b84ac-1321-427f-aa17-267ca6975798&client_id=aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' ]]; then
  pass "user-assigned client ID is appended to the IMDS request"
else
  fail "Expected user-assigned client ID in IMDS URL, got: $result"
fi

result="$(select_auth_mode '' '' 'legacy-pat')"
if [[ "$result" == 'pat|legacy-pat|'* ]]; then
  pass "PAT is used as an explicit fallback when IMDS is unavailable"
else
  fail "Expected PAT fallback, got: $result"
fi

if select_auth_mode '' '' '' >/dev/null 2>&1; then
  fail "Expected auth selection to fail without IMDS token or PAT"
else
  pass "auth selection fails when neither managed identity nor PAT is available"
fi

package_discovery_args() {
  local auth_mode="$1"
  local token="$2"

  if [[ "$auth_mode" == "managed_identity" ]]; then
    printf '%s\n' "-H|Accept: application/json" "-H|Authorization: ******"
  else
    printf '%s\n' "--user|user:${token}" "-H|Accept: application/json"
  fi
}

managed_args="$(package_discovery_args 'managed_identity' 'mi-token')"
if [[ "$managed_args" == *$'Authorization: ******'* ]] && [[ "$managed_args" != *$'--user|user:mi-token'* ]]; then
  pass "managed identity package discovery uses bearer auth instead of basic auth"
else
  fail "Expected bearer auth for managed identity package discovery, got: $managed_args"
fi

pat_args="$(package_discovery_args 'pat' 'legacy-pat')"
if [[ "$pat_args" == *$'--user|user:legacy-pat'* ]] && [[ "$pat_args" == *$'Accept: application/json'* ]]; then
  pass "PAT package discovery keeps basic auth and valid JSON accept header"
else
  fail "Expected basic auth plus JSON accept header for PAT package discovery, got: $pat_args"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
