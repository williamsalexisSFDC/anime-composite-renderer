# tools/validate_and_retry.sh
#
# Purpose:
# - Centralize VALIDATE + (optional) one-time auto-regenerate with tighter constraints
# - Used by validate_* jobs so the YAML stays readable and avoids copy/paste logic
#
# Contract (inputs via env vars):
#   REQUIRED:
#     VALIDATION_PROFILES_FILE   Path to config/validation/profiles.yml
#     VALIDATE_PROFILE           Profile key inside validate_profiles (e.g., v1_book1_strict_ip)
#     ATTEMPT1_IMAGE             Path to the attempt1 image (already downloaded)
#     OUT_DIR                    Output directory for reports/final artifact
#
#   OPTIONAL:
#     FAIL_SOFTLY                "true" or "false" (default: true)
#     MAX_RETRIES                integer (default: 1)
#     RERENDER_CMD               shell command to produce attempt2 image (ONLY used if retry is needed)
#     ATTEMPT2_IMAGE             Path where attempt2 should be written by RERENDER_CMD (default derived)
#
# Outputs (written to stdout + files):
#   - $OUT_DIR/final.png                 selected final image
#   - $OUT_DIR/final.validate.json       selected validation report (if exists)
#   - returns non-zero if final validation fails

set -euo pipefail

# ----------------------------
# Helpers
# ----------------------------
fail() { echo "ERROR: $*" >&2; exit 2; }
info() { echo "INFO:  $*" >&2; }

need_env() {
  local k="$1"
  [[ -n "${!k:-}" ]] || fail "Missing required env var: $k"
}

# ----------------------------
# Required inputs
# ----------------------------
need_env VALIDATION_PROFILES_FILE
need_env VALIDATE_PROFILE
need_env ATTEMPT1_IMAGE
need_env OUT_DIR

FAIL_SOFTLY="${FAIL_SOFTLY:-true}"
MAX_RETRIES="${MAX_RETRIES:-1}"
RERENDER_CMD="${RERENDER_CMD:-}"
ATTEMPT2_IMAGE="${ATTEMPT2_IMAGE:-${OUT_DIR}/attempt2.png}"

mkdir -p "$OUT_DIR"
mkdir -p "$OUT_DIR/reports"

ATTEMPT1_REPORT="${OUT_DIR}/reports/attempt1.validate.json"
ATTEMPT2_REPORT="${OUT_DIR}/reports/attempt2.validate.json"

FINAL_IMAGE="${OUT_DIR}/final.png"
FINAL_REPORT="${OUT_DIR}/final.validate.json"

# ----------------------------
# Attempt 1 — Validate (soft)
# ----------------------------
info "Validating attempt1: $ATTEMPT1_IMAGE"
set +e
validator validate \
  --profiles "$VALIDATION_PROFILES_FILE" \
  --profile "$VALIDATE_PROFILE" \
  --image "$ATTEMPT1_IMAGE" \
  --report "$ATTEMPT1_REPORT"
V1_RC=$?
set -e

# Prefer report truth if available; otherwise use exit code
PASSED_1="false"
if [[ -f "$ATTEMPT1_REPORT" ]]; then
  PASSED_1="$(jq -r '.passed' "$ATTEMPT1_REPORT" 2>/dev/null || echo "false")"
else
  [[ "$V1_RC" -eq 0 ]] && PASSED_1="true"
fi

if [[ "$PASSED_1" == "true" ]]; then
  info "Attempt1 PASSED. Selecting attempt1 as final."
  cp "$ATTEMPT1_IMAGE" "$FINAL_IMAGE"
  [[ -f "$ATTEMPT1_REPORT" ]] && cp "$ATTEMPT1_REPORT" "$FINAL_REPORT" || true
  echo "FINAL_IMAGE=$FINAL_IMAGE"
  exit 0
fi

info "Attempt1 FAILED."

# ----------------------------
# Retry gate
# ----------------------------
if [[ "$FAIL_SOFTLY" != "true" ]]; then
  info "FAIL_SOFTLY=false, failing hard after attempt1."
  # Keep artifacts for inspection
  cp "$ATTEMPT1_IMAGE" "$FINAL_IMAGE"
  [[ -f "$ATTEMPT1_REPORT" ]] && cp "$ATTEMPT1_REPORT" "$FINAL_REPORT" || true
  exit 1
fi

if [[ "$MAX_RETRIES" -lt 1 ]]; then
  info "MAX_RETRIES=0, failing hard after attempt1."
  cp "$ATTEMPT1_IMAGE" "$FINAL_IMAGE"
  [[ -f "$ATTEMPT1_REPORT" ]] && cp "$ATTEMPT1_REPORT" "$FINAL_REPORT" || true
  exit 1
fi

if [[ -z "$RERENDER_CMD" ]]; then
  info "No RERENDER_CMD provided; cannot retry. Failing hard."
  cp "$ATTEMPT1_IMAGE" "$FINAL_IMAGE"
  [[ -f "$ATTEMPT1_REPORT" ]] && cp "$ATTEMPT1_REPORT" "$FINAL_REPORT" || true
  exit 1
fi

# ----------------------------
# Attempt 2 — Re-render (tightened) then validate (hard)
# ----------------------------
info "Retrying once (tightened). Writing attempt2 -> $ATTEMPT2_IMAGE"
bash -lc "$RERENDER_CMD"

[[ -f "$ATTEMPT2_IMAGE" ]] || fail "RERENDER_CMD completed but ATTEMPT2_IMAGE not found: $ATTEMPT2_IMAGE"

info "Validating attempt2: $ATTEMPT2_IMAGE"
validator validate \
  --profiles "$VALIDATION_PROFILES_FILE" \
  --profile "$VALIDATE_PROFILE" \
  --image "$ATTEMPT2_IMAGE" \
  --report "$ATTEMPT2_REPORT"

PASSED_2="false"
if [[ -f "$ATTEMPT2_REPORT" ]]; then
  PASSED_2="$(jq -r '.passed' "$ATTEMPT2_REPORT" 2>/dev/null || echo "false")"
else
  PASSED_2="true" # validator returned 0 if no report created
fi

if [[ "$PASSED_2" != "true" ]]; then
  info "Attempt2 FAILED. Failing hard."
  cp "$ATTEMPT2_IMAGE" "$FINAL_IMAGE"
  [[ -f "$ATTEMPT2_REPORT" ]] && cp "$ATTEMPT2_REPORT" "$FINAL_REPORT" || true
  exit 1
fi

info "Attempt2 PASSED. Selecting attempt2 as final."
cp "$ATTEMPT2_IMAGE" "$FINAL_IMAGE"
[[ -f "$ATTEMPT2_REPORT" ]] && cp "$ATTEMPT2_REPORT" "$FINAL_REPORT" || true

echo "FINAL_IMAGE=$FINAL_IMAGE"
exit 0
