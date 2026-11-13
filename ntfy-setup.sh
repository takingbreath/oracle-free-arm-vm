#!/usr/bin/env bash
# ntfy-setup.sh - phone messages for grab-a1.sh through ntfy (https://ntfy.sh).
#
#   ./ntfy-setup.sh          make a private topic (if none), save it in config.env,
#                            make an Android QR code, send a test message
#   ./ntfy-setup.sh --test   only send a test message again
#
# The topic name is the only "password": anyone who knows it can read the
# messages. So the name is long and random, and it stays out of Git.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="$HERE/config.env"
NTFY_SERVER="${NTFY_SERVER:-https://ntfy.sh}"
HOST="${NTFY_SERVER#https://}"; HOST="${HOST#http://}"; HOST="${HOST%/}"

[ -f "$CONFIG" ] || cp "$HERE/config.env.example" "$CONFIG"

topic="$(sed -n 's/^NTFY_TOPIC=//p' "$CONFIG" | tail -n 1 | tr -d '"'"'"' ')"
if [ -z "$topic" ]; then
  topic="oracle-vm-$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 12)"
  if grep -q '^#\{0,1\} *NTFY_TOPIC=' "$CONFIG"; then
    # Replace the (commented or empty) line.
    tmp="$(mktemp)"
    awk -v t="$topic" '/^#? *NTFY_TOPIC=/ && !done { print "NTFY_TOPIC=" t; done = 1; next } { print }' "$CONFIG" >"$tmp" && cat "$tmp" >"$CONFIG"
    rm -f "$tmp"
  else
    printf '\nNTFY_TOPIC=%s\n' "$topic" >>"$CONFIG"
  fi
  echo "New topic saved in config.env."
fi

web_url="${NTFY_SERVER%/}/$topic"
android_url="ntfy://$HOST/$topic?display=Oracle%20VM"

send_test() {
  if curl -fsS -m 20 -H "Title: ntfy works" -H "Priority: 4" -H "Tags: white_check_mark" \
      --data-binary "Test from the Oracle VM script. You get a message here when the VM is ready." \
      "$web_url" >/dev/null; then
    echo "Test message sent."
  else
    echo "Could not send the test message. Check the internet connection."
    return 1
  fi
}

if [ "${1:-}" = "--test" ]; then
  send_test
  exit $?
fi

if ! command -v qrencode >/dev/null 2>&1 && command -v brew >/dev/null 2>&1; then
  echo "Installing qrencode (for the QR codes)..."
  brew install qrencode >/dev/null 2>&1 || true
fi
if command -v qrencode >/dev/null 2>&1; then
  qrencode -s 10 -m 2 -o "$HERE/ntfy-qr-android.png" "$android_url"
  echo
  echo "Android QR (subscribes in the ntfy app):"
  qrencode -t ANSIUTF8 -m 2 "$android_url"
  qr_note="Android QR code: $HERE/ntfy-qr-android.png"
else
  qr_note="No QR code (qrencode is not installed). Use the topic name."
fi

cat <<EOF

Topic:        $topic
Server:       ${NTFY_SERVER%/}  (the default server in the app)
Web page:     $web_url
Android link: $android_url
$qr_note

Phone steps:
  1. Install the ntfy app.
     Android: https://play.google.com/store/apps/details?id=io.heckel.ntfy
     iPhone:  https://apps.apple.com/us/app/ntfy/id1625396347
  2. Android: scan the QR code with the camera and open the link in ntfy.
     iPhone (or if the QR does not work): in the app tap "+", type the topic
     name above, keep the default server, tap Subscribe.
  3. Allow notifications for ntfy when the phone asks.
EOF
echo
send_test
