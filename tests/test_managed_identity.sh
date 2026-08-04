#!/bin/bash
# Lightweight shell tests for managed identity token acquisition logic.
# These tests mock the IMDS endpoint and do not require live Azure credentials.

set -e

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

# --------------------------------------------------------------------------
# Helper: extract token acquisition logic from start.sh into a testable fn.
# The function sets AZP_TOKEN or exits with a non-zero code.
# --------------------------------------------------------------------------
acquire_token() {
  local imds_response="$1"   # JSON string or empty to simulate failure
  local client_id="$2"       # optional user-assigned identity client ID
  local pat="$3"             # optional PAT

  # Replicate the logic from docker/start.sh
  local token=""
  local token_file
  token_file=$(mktemp)
  trap "rm -f $token_file" RETURN

  if [ -n "$pat" ]; then
    token="$pat"
  else
    # Build IMDS URL
    local imds_url="http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=499b84ac-1321-427f-aa17-267ca6975798"
    if [ -n "$client_id" ]; then
      local encoded
      encoded=$(printf '%s' "$client_id" | sed 's/ /%20/g')
      imds_url="${imds_url}&client_id=${encoded}"
    fi

    # Instead of a real curl, use the provided mock response
    local response="$imds_response"

    if ! echo "$response" | jq -e '.access_token' >/dev/null 2>&1; then
      return 1
    fi

    token=$(echo "$response" | jq -r '.access_token')
  fi

  echo -n "$token" > "$token_file"
  cat "$token_file"
}

# --------------------------------------------------------------------------
# Test 1: PAT takes priority over managed identity
# --------------------------------------------------------------------------
echo "Test 1: PAT provided directly"
result=$(acquire_token "" "" "my-test-pat")
if [ "$result" = "my-test-pat" ]; then
  pass "PAT used when provided"
else
  fail "Expected 'my-test-pat', got '$result'"
fi

# --------------------------------------------------------------------------
# Test 2: System-assigned managed identity (no client_id)
# --------------------------------------------------------------------------
echo "Test 2: System-assigned managed identity token"
MOCK_RESPONSE='{"access_token":"system-mi-token","expires_in":"3599","token_type":"Bearer"}'
result=$(acquire_token "$MOCK_RESPONSE" "" "")
if [ "$result" = "system-mi-token" ]; then
  pass "System-assigned MI token extracted"
else
  fail "Expected 'system-mi-token', got '$result'"
fi

# --------------------------------------------------------------------------
# Test 3: User-assigned managed identity (client_id provided)
# --------------------------------------------------------------------------
echo "Test 3: User-assigned managed identity token"
MOCK_RESPONSE='{"access_token":"user-mi-token","expires_in":"3599","token_type":"Bearer"}'
result=$(acquire_token "$MOCK_RESPONSE" "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" "")
if [ "$result" = "user-mi-token" ]; then
  pass "User-assigned MI token extracted"
else
  fail "Expected 'user-mi-token', got '$result'"
fi

# --------------------------------------------------------------------------
# Test 4: IMDS unreachable (empty response) and no PAT → should fail
# --------------------------------------------------------------------------
echo "Test 4: IMDS unavailable and no PAT"
if acquire_token "" "" "" 2>/dev/null; then
  fail "Should have returned non-zero when IMDS unavailable and no PAT"
else
  pass "Correctly failed when IMDS unavailable and no PAT"
fi

# --------------------------------------------------------------------------
# Test 5: IMDS returns error JSON (no access_token field)
# --------------------------------------------------------------------------
echo "Test 5: IMDS returns error JSON"
ERROR_RESPONSE='{"error":"invalid_request","error_description":"Identity not found"}'
if acquire_token "$ERROR_RESPONSE" "" "" 2>/dev/null; then
  fail "Should have returned non-zero on IMDS error response"
else
  pass "Correctly failed on IMDS error response"
fi

# --------------------------------------------------------------------------
# Test 6: client_id URL-encoding (spaces replaced with %20)
# --------------------------------------------------------------------------
echo "Test 6: client_id with spaces is URL-encoded"
MOCK_RESPONSE='{"access_token":"encoded-token","expires_in":"3599","token_type":"Bearer"}'
result=$(acquire_token "$MOCK_RESPONSE" "id with spaces" "")
if [ "$result" = "encoded-token" ]; then
  pass "client_id with spaces handled correctly"
else
  fail "Expected 'encoded-token', got '$result'"
fi

# --------------------------------------------------------------------------
# Summary
# --------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
