#!/usr/bin/env bash
# Tests grab-a1.sh against a fake 'oci' command. No Oracle account needed.
# Run: bash tests/fake-oci-test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$WORK/bin"
printf '[DEFAULT]\ntenancy=ocid1.tenancy.oc1..fake\nregion=ap-mumbai-1\n' >"$WORK/config"
echo "ssh-ed25519 AAAAfake test" >"$WORK/key.pub"

# The fake CLI. FAKE_LAUNCH is a space-separated list of answers, one per launch:
# ok | capacity | throttle | limit | internal | invalid
cat >"$WORK/bin/oci" <<'FAKE'
#!/usr/bin/env bash
args="$*"
n_file="$FAKE_DIR/launches"
case "$args" in
  *"region-subscription list"*) echo "ap-mumbai-1" ;;
  *"availability-domain list"*) echo "ab:AP-MUMBAI-1-AD-1 ab:AP-MUMBAI-1-AD-2" ;;
  *"image list"*) echo "ocid1.image.oc1..fake Canonical-Ubuntu-24.04-aarch64-test" ;;
  *"subnet list"*) echo "ocid1.subnet.oc1..fake public-subnet" ;;
  *"instance list "*)
    if [ -f "$FAKE_DIR/created" ]; then echo "ocid1.instance.oc1..late"; fi ;;
  *"instance launch"*)
    n=$(( $(cat "$n_file" 2>/dev/null || echo 0) + 1 )); echo "$n" >"$n_file"
    echo "$args" >>"$FAKE_DIR/launch-args"
    set -- $FAKE_LAUNCH; shift $((n - 1)); kind="${1:-capacity}"
    err() { printf 'ServiceError:\n{\n    "code": "%s",\n    "message": "%s",\n    "status": %s\n}\n' "$1" "$2" "$3"; exit 1; }
    case "$kind" in
      ok) echo "ocid1.instance.oc1..new" ;;
      capacity) err InternalError "Out of host capacity." 500 ;;
      throttle) err TooManyRequests "Too many requests for the user" 429 ;;
      limit) err LimitExceeded "The following service limits were exceeded: standard-a1-core-count" 400 ;;
      internal) touch "$FAKE_DIR/created"; err InternalError "Internal error" 500 ;;
      invalid) err InvalidParameter "Invalid shape config" 400 ;;
    esac ;;
  *"instance get"*) echo "RUNNING" ;;
  *"list-vnics"*) echo "203.0.113.7" ;;
  *) echo "fake oci: unhandled: $args" >&2; exit 2 ;;
esac
FAKE
chmod +x "$WORK/bin/oci"

pass=0; fail=0
run() { # run <name> <FAKE_LAUNCH> <expected rc> <expected text> [extra env...]
  local name="$1" launches="$2" want_rc="$3" want_text="$4"; shift 4
  local d="$WORK/$name"; mkdir -p "$d"
  out="$(env PATH="$WORK/bin:$PATH" FAKE_DIR="$d" FAKE_LAUNCH="$launches" \
    OCI_CONFIG_FILE="$WORK/config" SSH_PUBLIC_KEY_FILE="$WORK/key.pub" LOG_FILE="$d/log" \
    RETRY_SECONDS=1 "$@" bash "$ROOT/grab-a1.sh" ${RUN_ARG:-} 2>&1)"
  rc=$?
  if [ "$rc" = "$want_rc" ] && printf '%s' "$out" | grep -q -- "$want_text"; then
    pass=$((pass + 1)); echo "PASS $name"
  else
    fail=$((fail + 1)); echo "FAIL $name (rc=$rc, want $want_rc, text '$want_text')"; echo "$out" | sed 's/^/    /'
  fi
}

run capacity-then-ok   "capacity capacity ok" 0 "SUCCESS on attempt 3"
run rotates-ads        "capacity ok"          0 "AD-2"
run throttle-backoff   "throttle capacity ok" 0 "Next wait 2s"
run limit-stops        "limit"                1 "account limit is too low"
run lost-answer        "internal"             0 "created after all"
run unknown-stops      "invalid"              1 "Unexpected answer"
run max-attempts       "capacity capacity capacity" 1 "MAX_ATTEMPTS=2" MAX_ATTEMPTS=2
run prints-ip          "ok"                   0 "203.0.113.7"
RUN_ARG=--check run check-launches-nothing "ok" 0 "Check passed"
run no-retry-flag      "ok"                   0 "SUCCESS"

# The check run must not call launch; the real runs must pass --no-retry.
[ ! -f "$WORK/check-launches-nothing/launches" ] && echo "PASS check made no launch" && pass=$((pass + 1)) \
  || { echo "FAIL check made a launch"; fail=$((fail + 1)); }
grep -q -- "--no-retry" "$WORK/no-retry-flag/launch-args" && echo "PASS launch uses --no-retry" && pass=$((pass + 1)) \
  || { echo "FAIL launch without --no-retry"; fail=$((fail + 1)); }

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
