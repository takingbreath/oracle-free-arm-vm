#!/usr/bin/env bash
# grab-a1.sh - keep asking Oracle Cloud for a free Ampere A1 (Arm) VM until one is created.
#
# Oracle often answers "Out of host capacity" for free A1 VMs. This script
# retries the launch until Oracle has space, then prints the public IP.
#
# Usage:
#   ./grab-a1.sh --check      # find everything, launch nothing
#   ./grab-a1.sh              # retry until the VM exists
#
# Settings come from ./config.env (copy config.env.example). A setting that
# config.env does not set can come from the environment. See README.md.
#
# Works with the bash 3.2 that ships with macOS and with Linux bash.

set -u

# ---------- settings (defaults; override in config.env or the environment) ----------
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$HERE/config.env" ]; then
  # shellcheck disable=SC1091
  . "$HERE/config.env"
fi

OCI_PROFILE="${OCI_PROFILE:-DEFAULT}"
OCI_CONFIG_FILE="${OCI_CONFIG_FILE:-$HOME/.oci/config}"
# Always Free A1 since 15 June 2026: 2 OCPUs + 12 GB in total per tenancy.
OCPUS="${OCPUS:-2}"
MEMORY_GB="${MEMORY_GB:-12}"
BOOT_VOLUME_GB="${BOOT_VOLUME_GB:-50}"        # free: 200 GB total for all boot + block volumes
DISPLAY_NAME="${DISPLAY_NAME:-free-a1}"
SSH_PUBLIC_KEY_FILE="${SSH_PUBLIC_KEY_FILE:-$HOME/.ssh/oracle_a1.pub}"
UBUNTU_VERSION="${UBUNTU_VERSION:-24.04}"
COMPARTMENT_ID="${COMPARTMENT_ID:-}"          # empty = root compartment (the tenancy)
SUBNET_ID="${SUBNET_ID:-}"                    # empty = find a public subnet, or make one
IMAGE_ID="${IMAGE_ID:-}"                      # empty = newest Canonical Ubuntu for A1
AVAILABILITY_DOMAINS="${AVAILABILITY_DOMAINS:-}"  # empty = every AD in the region
RETRY_SECONDS="${RETRY_SECONDS:-60}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-0}"             # 0 = no limit
LOG_FILE="${LOG_FILE:-$HERE/grab-a1.log}"

SHAPE="VM.Standard.A1.Flex"
FREE_OCPUS=2
FREE_MEMORY_GB=12

# ---------- helpers ----------
log() {
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S') $*"
  echo "$line"
  echo "$line" >>"$LOG_FILE" 2>/dev/null || true
}

die() {
  log "STOP: $*"
  exit 1
}

# Run the OCI CLI with the chosen profile. Retries ask for no prompts.
ocx() {
  oci --config-file "$OCI_CONFIG_FILE" --profile "$OCI_PROFILE" "$@"
}

config_value() { # config_value <key> - read a key from the chosen profile in the OCI config
  awk -v section="[$OCI_PROFILE]" -v key="$1" '
    $0 == section { inside = 1; next }
    /^\[/ { inside = 0 }
    inside {
      split($0, kv, "=")
      k = kv[1]; gsub(/[ \t]/, "", k)
      if (k == key) { v = substr($0, index($0, "=") + 1); gsub(/^[ \t]+|[ \t]+$/, "", v); print v; exit }
    }' "$OCI_CONFIG_FILE"
}

# ---------- discovery ----------
check_tools() {
  command -v oci >/dev/null 2>&1 || die "The OCI CLI is not installed. Mac: 'brew install oci-cli'. Linux: see README.md."
  [ -f "$OCI_CONFIG_FILE" ] || die "No OCI config at $OCI_CONFIG_FILE. Make an API key first (README.md, step 3)."
  [ -f "$SSH_PUBLIC_KEY_FILE" ] || die "No SSH public key at $SSH_PUBLIC_KEY_FILE. Run: ssh-keygen -t ed25519 -f ${SSH_PUBLIC_KEY_FILE%.pub}"
  case "$SSH_PUBLIC_KEY_FILE" in
    *.pub) ;;
    *) die "SSH_PUBLIC_KEY_FILE must be the PUBLIC key (the .pub file), not the private key." ;;
  esac
}

discover_tenancy() {
  TENANCY_ID="$(config_value tenancy)"
  REGION="$(config_value region)"
  [ -n "$TENANCY_ID" ] || die "No 'tenancy=' line in profile [$OCI_PROFILE] of $OCI_CONFIG_FILE."
  [ -n "$REGION" ] || die "No 'region=' line in profile [$OCI_PROFILE] of $OCI_CONFIG_FILE."
  [ -n "$COMPARTMENT_ID" ] || COMPARTMENT_ID="$TENANCY_ID"

  local home out
  if ! out="$(ocx iam region-subscription list --tenancy-id "$TENANCY_ID" \
      --query 'data[?"is-home-region"]."region-name" | [0]' --raw-output 2>&1)"; then
    die "The OCI CLI cannot sign in. Check the API key in $OCI_CONFIG_FILE. Oracle said: $out"
  fi
  home="$out"
  if [ "$home" != "$REGION" ]; then
    die "Region in the config is $REGION but your home region is $home. Free VMs exist only in the home region. Set region=$home in $OCI_CONFIG_FILE."
  fi
  log "Tenancy OK. Home region: $REGION."
}

discover_ads() {
  if [ -z "$AVAILABILITY_DOMAINS" ]; then
    AVAILABILITY_DOMAINS="$(ocx iam availability-domain list -c "$TENANCY_ID" \
      --query "join(' ', data[].name)" --raw-output 2>&1)" || die "Cannot list availability domains: $AVAILABILITY_DOMAINS"
  fi
  [ -n "$AVAILABILITY_DOMAINS" ] || die "No availability domains found."
  log "Availability domains: $AVAILABILITY_DOMAINS"
}

discover_image() {
  if [ -z "$IMAGE_ID" ]; then
    local out
    out="$(ocx compute image list -c "$COMPARTMENT_ID" \
      --operating-system "Canonical Ubuntu" --operating-system-version "$UBUNTU_VERSION" \
      --shape "$SHAPE" --sort-by TIMECREATED --sort-order DESC --all \
      --query "data[?!contains(\"display-name\", 'Minimal')].join(' ', [id, \"display-name\"]) | [0]" \
      --raw-output 2>&1)" || die "Cannot list images: $out"
    case "$out" in
      ocid1.image.*) IMAGE_ID="${out%% *}"; log "Image: ${out#* }" ;;
      *) die "No Ubuntu $UBUNTU_VERSION image for $SHAPE in $REGION. Set UBUNTU_VERSION or IMAGE_ID." ;;
    esac
  else
    log "Image: $IMAGE_ID (from settings)"
  fi
}

create_network() {
  log "No public subnet found. Making one (VCN 'free-a1-vcn', internet gateway, public subnet). This costs nothing."
  local vcn igw rt subnet out
  vcn="$(ocx network vcn create -c "$COMPARTMENT_ID" --cidr-blocks '["10.0.0.0/16"]' \
    --display-name free-a1-vcn --dns-label freea1 \
    --wait-for-state AVAILABLE --query 'data.id' --raw-output 2>/dev/null | tail -n 1)"
  case "$vcn" in ocid1.vcn.*) ;; *) die "Could not make the VCN. Make one in the console: Networking > Virtual cloud networks > Start VCN Wizard > 'Create VCN with Internet Connectivity'." ;; esac

  igw="$(ocx network internet-gateway create -c "$COMPARTMENT_ID" --vcn-id "$vcn" --is-enabled true \
    --display-name free-a1-igw --wait-for-state AVAILABLE --query 'data.id' --raw-output 2>/dev/null | tail -n 1)"
  case "$igw" in ocid1.internetgateway.*) ;; *) die "Could not make the internet gateway in VCN $vcn." ;; esac

  rt="$(ocx network vcn get --vcn-id "$vcn" --query 'data."default-route-table-id"' --raw-output 2>&1)" \
    || die "Could not read the route table of VCN $vcn: $rt"
  out="$(ocx network route-table update --rt-id "$rt" --force \
    --route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"$igw\"}]" 2>&1)" \
    || die "Could not add the internet route: $out"

  # The default security list of a new VCN already lets SSH (port 22) in.
  subnet="$(ocx network subnet create -c "$COMPARTMENT_ID" --vcn-id "$vcn" --cidr-block 10.0.0.0/24 \
    --display-name free-a1-public --dns-label public \
    --wait-for-state AVAILABLE --query 'data.id' --raw-output 2>/dev/null | tail -n 1)"
  case "$subnet" in ocid1.subnet.*) ;; *) die "Could not make the subnet in VCN $vcn." ;; esac
  SUBNET_ID="$subnet"
  log "Network ready. Subnet: $SUBNET_ID"
}

discover_subnet() {
  if [ -n "$SUBNET_ID" ]; then
    log "Subnet: $SUBNET_ID (from settings)"
    return
  fi
  local out
  out="$(ocx network subnet list -c "$COMPARTMENT_ID" --all \
    --query 'data[?"prohibit-public-ip-on-vnic"==`false` && "lifecycle-state"==`AVAILABLE`].join(`" "`, [id, "display-name"]) | [0]' \
    --raw-output 2>&1)" || die "Cannot list subnets: $out"
  case "$out" in
    ocid1.subnet.*)
      SUBNET_ID="${out%% *}"
      log "Subnet: ${out#* } (public)"
      ;;
    *)
      if [ "$CHECK_ONLY" = 1 ]; then
        log "Subnet: none yet. A real run makes a free VCN and public subnet first."
      else
        create_network
      fi
      ;;
  esac
}

existing_instance() { # prints the OCID of a live instance with our name, if there is one
  ocx compute instance list -c "$COMPARTMENT_ID" --display-name "$DISPLAY_NAME" --all \
    --query 'data[?"lifecycle-state"!=`TERMINATED` && "lifecycle-state"!=`TERMINATING`] | [0].id' \
    --raw-output 2>/dev/null | grep '^ocid1\.instance\.' || true
}

check_size() {
  local over
  over="$(awk -v o="$OCPUS" -v m="$MEMORY_GB" -v fo="$FREE_OCPUS" -v fm="$FREE_MEMORY_GB" 'BEGIN { print (o > fo || m > fm) ? 1 : 0 }')"
  if [ "$over" = 1 ]; then
    log "WARNING: $OCPUS OCPUs / $MEMORY_GB GB is above the Always Free size ($FREE_OCPUS OCPUs / $FREE_MEMORY_GB GB)."
    log "WARNING: A free account refuses this (LimitExceeded). Pay As You Go accepts it. See README.md about cost."
  fi
}

# ---------- after success ----------
report_instance() {
  local id="$1" ip="" state="" i=0
  log "Waiting for the VM to start (up to 10 minutes)..."
  while [ "$i" -lt 60 ]; do
    state="$(ocx compute instance get --instance-id "$id" --query 'data."lifecycle-state"' --raw-output 2>/dev/null || true)"
    if [ "$state" = RUNNING ]; then
      ip="$(ocx compute instance list-vnics --instance-id "$id" --query 'data[0]."public-ip"' --raw-output 2>/dev/null \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)"
      [ -n "$ip" ] && break
    fi
    i=$((i + 1))
    sleep 10
  done
  log "State: ${state:-unknown}"
  log "Instance: $id"
  log "Public IP: ${ip:-not ready yet - see the Oracle console}"
  log "Log in:    ssh -i ${SSH_PUBLIC_KEY_FILE%.pub} ubuntu@${ip:-<public-ip>}"
  printf '\a'
}

# ---------- main loop ----------
classify() { # classify <output> -> capacity | throttled | limit | auth | transient | other
  case "$1" in
    *"Out of host capacity"*|*"out of host capacity"*) echo capacity ;;
    *TooManyRequests*|*'"status": 429'*) echo throttled ;;
    *LimitExceeded*|*QuotaExceeded*) echo limit ;;
    *NotAuthenticated*|*'"status": 401'*) echo auth ;;
    *InternalError*|*'"status": 500'*|*'"status": 502'*|*'"status": 503'*|*'"status": 504'*) echo transient ;;
    *RequestException*|*ConnectTimeout*|*ReadTimeout*|*"timed out"*|*"Connection aborted"*|*"Max retries exceeded"*) echo transient ;;
    *) echo other ;;
  esac
}

launch_once() { # launch_once <ad> -> prints CLI output; exit code of the CLI
  # --no-retry: one request per attempt. Without it the CLI repeats a 500
  # ("Out of host capacity") up to 8 times on its own, which hides the pace.
  ocx --no-retry compute instance launch \
    --compartment-id "$COMPARTMENT_ID" \
    --availability-domain "$1" \
    --shape "$SHAPE" \
    --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEMORY_GB}" \
    --image-id "$IMAGE_ID" \
    --subnet-id "$SUBNET_ID" \
    --assign-public-ip true \
    --boot-volume-size-in-gbs "$BOOT_VOLUME_GB" \
    --ssh-authorized-keys-file "$SSH_PUBLIC_KEY_FILE" \
    --display-name "$DISPLAY_NAME" \
    --query 'data.id' --raw-output 2>&1
}

main() {
  CHECK_ONLY=0
  case "${1:-}" in
    --check) CHECK_ONLY=1 ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    "") ;;
    *) die "Unknown option '$1'. Use --check or no option." ;;
  esac

  check_tools
  log "Profile [$OCI_PROFILE] from $OCI_CONFIG_FILE. Asking for $SHAPE, $OCPUS OCPUs, $MEMORY_GB GB, boot volume $BOOT_VOLUME_GB GB, name '$DISPLAY_NAME'."
  check_size
  discover_tenancy
  discover_ads
  discover_image
  discover_subnet

  local found
  found="$(existing_instance)"
  if [ -n "$found" ]; then
    log "A VM named '$DISPLAY_NAME' already exists: $found. Nothing to do."
    [ "$CHECK_ONLY" = 1 ] || report_instance "$found"
    exit 0
  fi

  if [ "$CHECK_ONLY" = 1 ]; then
    log "Check passed. Run without --check to start retrying."
    exit 0
  fi

  local attempt=0 wait="$RETRY_SECONDS" ad out kind
  # shellcheck disable=SC2206
  local ads=($AVAILABILITY_DOMAINS)
  while :; do
    for ad in "${ads[@]}"; do
      attempt=$((attempt + 1))
      out="$(launch_once "$ad")"
      case "$out" in
        ocid1.instance.*)
          log "SUCCESS on attempt $attempt in $ad."
          report_instance "$out"
          exit 0
          ;;
      esac
      kind="$(classify "$out")"
      case "$kind" in
        capacity)  log "Attempt $attempt ($ad): out of host capacity."; wait="$RETRY_SECONDS" ;;
        throttled) wait=$((wait * 2)); [ "$wait" -gt 600 ] && wait=600; log "Attempt $attempt ($ad): too many requests. Next wait ${wait}s." ;;
        transient)
          log "Attempt $attempt ($ad): temporary error. $(echo "$out" | grep -m1 -E '"message"|Error' | tr -s ' ')"
          # A launch can succeed even when the answer is lost. Check before trying again.
          found="$(existing_instance)"
          if [ -n "$found" ]; then
            log "The VM was created after all."
            report_instance "$found"
            exit 0
          fi
          ;;
        limit) echo "$out" >>"$LOG_FILE"; die "Oracle says the account limit is too low for $OCPUS OCPUs / $MEMORY_GB GB. Always Free allows $FREE_OCPUS OCPUs / $FREE_MEMORY_GB GB in total, minus what other A1 VMs use. Lower OCPUS / MEMORY_GB." ;;
        auth) die "Oracle refused the API key. Check $OCI_CONFIG_FILE." ;;
        *) echo "$out"; echo "$out" >>"$LOG_FILE"; die "Unexpected answer from Oracle (above). Fix it, then run the script again." ;;
      esac
      if [ "$MAX_ATTEMPTS" -gt 0 ] && [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
        die "Reached MAX_ATTEMPTS=$MAX_ATTEMPTS without a VM."
      fi
      sleep "$wait"
    done
  done
}

# Run main only when executed, not when sourced (the tests source this file).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
