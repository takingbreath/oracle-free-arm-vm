#!/usr/bin/env bash
# Tests grab-a1.sh against fake 'oci' and 'curl' commands. No Oracle account,
# no ntfy message, no network. Run: bash tests/fake-oci-test.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# A clean copy of the script, so a local config.env cannot change the tests.
mkdir -p "$WORK/bin" "$WORK/repo"
cp "$ROOT/grab-a1.sh" "$WORK/repo/"
SCRIPT="$WORK/repo/grab-a1.sh"
printf '[ORACLE_A1]\ntenancy=ocid1.tenancy.oc1..fake\nregion=ap-mumbai-1\n' >"$WORK/config"
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
# The fake curl writes each ntfy message to $FAKE_DIR/ntfy.
cat >"$WORK/bin/curl" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$FAKE_DIR/ntfy"
FAKE
chmod +x "$WORK/bin/oci" "$WORK/bin/curl"

pass=0; fail=0
ok() { pass=$((pass + 1)); echo "PASS $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

run() { # run <name> <FAKE_LAUNCH> <expected rc> <expected text> [extra env...]
  local name="$1" launches="$2" want_rc="$3" want_text="$4"; shift 4
  local d="$WORK/$name"; mkdir -p "$d"
  out="$(env PATH="$WORK/bin:$PATH" FAKE_DIR="$d" FAKE_LAUNCH="$launches" \
    OCI_CONFIG_FILE="$WORK/config" SSH_PUBLIC_KEY_FILE="$WORK/key.pub" LOG_FILE="$d/log" \
    RETRY_SECONDS=1 NTFY_TOPIC=test-topic "$@" "${TEST_BASH:-bash}" "$SCRIPT" ${RUN_ARG:-} 2>&1)"
  rc=$?
  if [ "$rc" = "$want_rc" ] && printf '%s' "$out" | grep -q -- "$want_text"; then
    ok "$name"
  else
    bad "$name (rc=$rc, want $want_rc, text '$want_text')"; echo "$out" | sed 's/^/    /'
  fi
}
sent() { # sent <test name> <text> - did that test send an ntfy message with this text?
  grep -q -- "$2" "$WORK/$1/ntfy" 2>/dev/null
}

# Retry logic
run capacity-then-ok   "capacity capacity ok" 0 "SUCCESS on attempt 3"
run rotates-ads        "capacity ok"          0 "AD-2"
run throttle-backoff   "throttle capacity ok" 0 "Next wait 2s"
run limit-stops        "limit"                1 "account limit is too low"
run lost-answer        "internal"             0 "created after all"
run unknown-stops      "invalid"              1 "Unexpected answer"
run max-attempts       "capacity capacity capacity" 1 "MAX_ATTEMPTS=2" MAX_ATTEMPTS=2
run prints-ip          "ok"                   0 "203.0.113.7"
RUN_ARG=--check run check-launches-nothing "ok" 0 "Check passed"
run heartbeat          "capacity capacity capacity ok" 0 "Still trying" HEARTBEAT_HOURS=0.0003

[ ! -f "$WORK/check-launches-nothing/launches" ] && ok "check made no launch" || bad "check made a launch"
grep -q -- "--no-retry" "$WORK/prints-ip/launch-args" && ok "launch uses --no-retry" || bad "launch without --no-retry"

# ntfy messages
sent prints-ip "Oracle VM search started" && ok "ntfy: start message" || bad "ntfy: no start message"
sent prints-ip "Oracle VM is ready" && sent prints-ip "203.0.113.7" && ok "ntfy: ready message with IP" || bad "ntfy: no ready message with IP"
sent prints-ip "ntfy.sh/test-topic" && ok "ntfy: right topic URL" || bad "ntfy: wrong topic URL"
sent limit-stops "Oracle VM script stopped" && ok "ntfy: stop message on error" || bad "ntfy: no stop message on error"
sent heartbeat "Still trying for the Oracle VM" && ok "ntfy: heartbeat message" || bad "ntfy: no heartbeat message"
[ ! -f "$WORK/check-launches-nothing/ntfy" ] && ok "ntfy: --check sends nothing" || bad "ntfy: --check sent a message"

# A stop signal during the wait is handled at once, with a message.
d="$WORK/signal"; mkdir -p "$d"
env PATH="$WORK/bin:$PATH" FAKE_DIR="$d" FAKE_LAUNCH="capacity capacity" OCI_CONFIG_FILE="$WORK/config" \
  SSH_PUBLIC_KEY_FILE="$WORK/key.pub" LOG_FILE="$d/log" RETRY_SECONDS=30 NTFY_TOPIC=test-topic \
  "${TEST_BASH:-bash}" "$SCRIPT" >/dev/null 2>&1 &
pid=$!
sleep 2
d2="$WORK/second"; mkdir -p "$d2"
out2="$(env PATH="$WORK/bin:$PATH" FAKE_DIR="$d2" FAKE_LAUNCH="ok" OCI_CONFIG_FILE="$WORK/config" \
  SSH_PUBLIC_KEY_FILE="$WORK/key.pub" LOG_FILE="$d2/log" NTFY_TOPIC=test-topic "${TEST_BASH:-bash}" "$SCRIPT" 2>&1)"
rc2=$?
if [ "$rc2" = 1 ] && printf '%s' "$out2" | grep -q "Another copy is already running" && [ ! -f "$d2/launches" ]; then
  ok "second copy refused while one runs"
else bad "second copy: rc=$rc2 $out2"; fi
start=$(date +%s); kill -TERM "$pid"; wait "$pid"; rc=$?; took=$(( $(date +%s) - start ))
if [ "$rc" = 130 ] && [ "$took" -le 3 ] && sent signal "Stopped by hand"; then ok "signal: stops at once with a message"
else bad "signal: rc=$rc took=${took}s"; fi
[ ! -f "$WORK/repo/grab-a1.pid" ] && ok "pid file removed after stop" || bad "pid file left after stop"

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
