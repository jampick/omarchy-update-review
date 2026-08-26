#!/bin/bash
# Shape and safety tests for bin/omarchy-update-scan.
#
# These run against the real system, read-only. They assert the contract the
# QML panel depends on: always valid JSON, always exit 0, always under the byte
# cap that keeps a runaway process from growing the shell.

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

SCAN=./bin/omarchy-update-scan
pass=0
fail=0

ok() { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
no() { printf '  FAIL  %s\n' "$1"; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else no "$1"; fi; }

echo "omarchy-update-scan"

# --- contract --------------------------------------------------------------

out=$("$SCAN" --nosync --no-aur)
rc=$?

check "exits 0 even when it has nothing good to say" "(( rc == 0 ))"
check "emits valid JSON" "jq -e . >/dev/null 2>&1 <<<\"\$out\""
check "carries every key the panel reads" \
  "jq -e 'has(\"ok\") and has(\"error\") and has(\"omarchy\") and has(\"packages\") and has(\"aur\") and has(\"dev\") and has(\"totalBytes\") and has(\"restartCount\")' >/dev/null <<<\"\$out\""

if jq -e '.ok' >/dev/null <<<"$out"; then
  check "every package has a name and both versions" \
    "jq -e '(.packages | map(select((.name | length) > 0 and (.from | length) > 0 and (.to | length) > 0)) | length) == (.packages | length)' >/dev/null <<<\"\$out\""
  check "every tag is one the panel knows how to render" \
    "jq -e '(.packages | map(select(.tag == \"\" or .tag == \"reboot\" or .tag == \"restart\")) | length) == (.packages | length)' >/dev/null <<<\"\$out\""
  check "no package byte count is negative" \
    "jq -e '[.packages[] | select(.bytes < 0)] | length == 0' >/dev/null <<<\"\$out\""
  check "totalBytes covers at least the package list" \
    "jq -e '.totalBytes >= ([.packages[].bytes] | add // 0)' >/dev/null <<<\"\$out\""
  check "restartCount matches the tagged rows" \
    "jq -e '.restartCount == ([.packages[] | select(.tag != \"\")] | length)' >/dev/null <<<\"\$out\""
  check "omarchy is lifted out of the package list, not duplicated" \
    "jq -e '[.packages[] | select(.name == \"omarchy\" or .name == \"omarchy-dev\")] | length == 0' >/dev/null <<<\"\$out\""
else
  check "a failure still reads as a sentence to a person" \
    "jq -e '(.error | length) > 10 and (.error | endswith(\".\"))' >/dev/null <<<\"\$out\""
fi

# --- the byte cap ----------------------------------------------------------
#
# StdioCollector has no size limit, so this cap is the only thing standing
# between a runaway process and the shell's memory. Prove it fires, and that
# it fires as a readable error rather than as truncated JSON.

tiny=$(OMARCHY_UPDATE_SCAN_MAX_OUTPUT=64 "$SCAN" --nosync --no-aur)
check "output cap produces valid JSON, not a truncated document" \
  "jq -e . >/dev/null 2>&1 <<<\"\$tiny\""
check "output cap reports failure rather than a short list" \
  "jq -e '.ok == false and (.error | length) > 10' >/dev/null <<<\"\$tiny\""

tinylist=$(OMARCHY_UPDATE_SCAN_MAX_LIST=64 "$SCAN" --nosync --no-aur)
check "input cap produces valid JSON" "jq -e . >/dev/null 2>&1 <<<\"\$tinylist\""

# --- missing dependencies --------------------------------------------------

missing=$(PATH=/nonexistent "$SCAN" --nosync --no-aur 2>/dev/null)
check "says what is missing instead of dying when nothing is on PATH" \
  "jq -e '.ok == false and (.error | length) > 10' >/dev/null <<<\"\$missing\""

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
