#!/usr/bin/env bash
# Exercises bin/bt-call against stubbed pactl/wpctl/bluetoothctl output, so the
# parsing that the panel depends on is checked without Bluetooth hardware.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
tool="$here/../bin/bt-call"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/stub" "$tmp/cards" "$tmp/state" "$tmp/run"

cat > "$tmp/cards/cards.txt" <<'EOF'
	Name: bluez_card.68_CA_C4_C4_57_7C
	Driver: module-bluez5-device.c
	Properties:
		device.description = "Test Buds"
	Profiles:
		off: Off (sinks: 0, sources: 0, priority: 0, available: yes)
		a2dp-sink-sbc: High Fidelity Playback (A2DP Sink, codec SBC) (sinks: 1, sources: 0, priority: 132, available: yes)
		a2dp-sink-sbc_xq: High Fidelity Playback (A2DP Sink, codec SBC-XQ) (sinks: 1, sources: 0, priority: 131, available: yes)
		a2dp-sink: High Fidelity Playback (A2DP Sink, codec AAC) (sinks: 1, sources: 0, priority: 133, available: yes)
		headset-head-unit-cvsd: Headset (HSP/HFP, codec CVSD) (sinks: 1, sources: 1, priority: 100, available: yes)
		headset-head-unit: Headset (HSP/HFP, codec mSBC) (sinks: 1, sources: 1, priority: 101, available: yes)
	Active Profile: a2dp-sink
	Ports:
		headphone-output: Headphones (type: Headphones, priority: 0, latency offset: 0 usec, available)
EOF

cat > "$tmp/stub/pactl" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = list ] && [ "$2" = cards ]; then
  if [ "${3:-}" = short ]; then
    printf '70\tbluez_card.68_CA_C4_C4_57_7C\tPipeWire\tdriver\n'
  else
    cat "$FIX/cards.txt"
  fi
fi
exit 0
EOF

cat > "$tmp/stub/bluetoothctl" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = info ]; then
  printf 'Device %s\n\tAlias: Test Buds\n\tConnected: yes\n' "$2"
fi
exit 0
EOF

cat > "$tmp/stub/wpctl" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = settings ] && [ -z "${3:-}" ]; then
  printf 'Value: true\nSaved: true\n'
fi
exit 0
EOF

cat > "$tmp/stub/pw-dump" <<'EOF'
#!/usr/bin/env bash
echo '[]'
EOF

chmod +x "$tmp/stub/"*
run() {
  env PATH="$tmp/stub:$PATH" FIX="$tmp/cards" \
      XDG_STATE_HOME="$tmp/state" XDG_RUNTIME_DIR="$tmp/run" "$tool" "$@"
}

fail=0
check() {
  local what="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "  ok   $what"
  else
    echo "  FAIL $what: want '$want', got '$got'"
    fail=1
  fi
}

echo "info"
out=$(run info)
value() { printf '%s\n' "$out" | sed -n "s/^$1=//p"; }
check "name" "Test Buds" "$(value name)"
check "profile" "a2dp-sink" "$(value profile)"
check "codec" "aac" "$(value codec)"
check "in a call" "no" "$(value incall)"
check "call codecs" "cvsd,msbc" "$(value hfp_codecs)"
check "playback codecs" "sbc,sbc-xq,aac" "$(value a2dp_codecs)"
check "returns to" "aac" "$(value a2dp_pick)"
check "default" "aac" "$(value a2dp_default)"
check "watchdog" "inactive" "$(value daemon)"
case "$(value quirk)" in loaded|missing|n/a) echo "  ok   quirk reported" ;; *) echo "  FAIL quirk: $(value quirk)"; fail=1 ;; esac

echo "mode"
run mode music >/dev/null
check "music writes the flag" "music" "$(cat "$tmp/run/bt-call-manual" 2>/dev/null || true)"
run mode call >/dev/null
check "call writes the flag" "call" "$(cat "$tmp/run/bt-call-manual")"
run mode auto >/dev/null
check "auto clears the flag" "absent" "$([ -f "$tmp/run/bt-call-manual" ] && echo present || echo absent)"

echo "codec"
run codec sbc-xq >/dev/null
check "the pick is remembered" "a2dp-sink-sbc_xq" \
  "$(cat "$tmp/state/bt-call/a2dp-68_CA_C4_C4_57_7C" 2>/dev/null || true)"
out=$(run info)
check "info follows the pick" "sbc-xq" "$(value a2dp_pick)"

exit "$fail"
