#!/usr/bin/env bash
# Live drive: real fm-watch-arm --restart / fm-watch / fm-wake-drain on a disposable lab home.
set -u
R=$1; SC=$2
LAB=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")" && pwd -P); "$R/bin/fm-lab-home.sh" create "$LAB" >/dev/null
S="$LAB/state"
E() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE -u TMUX FM_HOME="$LAB" FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_ARM_CONFIRM_TIMEOUT=30 "$@"; }
arm() { E "$R/bin/fm-watch-arm.sh" --restart > "$1" 2>&1 & APID=$!; for i in $(seq 1 120); do grep -q '^watcher: started' "$1" && break; kill -0 $APID 2>/dev/null || break; sleep 0.1; done; }
closew() { kill -TERM "$(cat "$S/.watch.lock/pid")" 2>/dev/null; wait $APID 2>/dev/null; }
seen() { E bash -c '. "$1"; fm_wake_status_mark_current "$2" "$3"' _ "$R/bin/fm-wake-lib.sh" "$S" "$1"; }
cover() { local seq; seq=$(E "$R/bin/fm-branch-outcome.sh" append --task "$1" --verdict routine --summary "$1 finished" --wake "signal: $1"); E "$R/bin/fm-branch-outcome.sh" mark-read --through "$seq" >/dev/null; }
echo "### scenario: $SC  (scripts from $R)"
arm "$LAB/a1.out"; echo "--- first arm:"; cat "$LAB/a1.out"; closew
case $SC in
  covered) printf 'working: started\ndone: PR https://example.test/77 checks green\n' > "$S/covered.status"; seen "$S/covered.status"; cover covered ;;
  reserved) printf 'needs-decision [key=pending-reply-x]: written outside that namespace vocabulary\n' > "$S/foreign.status"; seen "$S/foreign.status" ;;
  mixed) printf 'working: started\ndone: PR https://example.test/77 checks green\n' > "$S/covered.status"; seen "$S/covered.status"; cover covered
         printf 'working: started\ndone: PR https://example.test/88 checks green\n' > "$S/fresh.status"; seen "$S/fresh.status" ;;
  noready) printf 'working: started\ndone: PR https://example.test/77 checks green\n' > "$S/covered.status"; seen "$S/covered.status"; cover covered; rm -f "$S/.branch-outcome-index-ready" ;;
esac
echo "--- state files: $(ls -A "$S" | grep -E 'status$|branch-outcome' | tr '\n' ' ')"
arm "$LAB/a2.out"; sleep 3
echo "--- recovery arm output after 3s (arm still alive=$(kill -0 $APID 2>/dev/null && echo yes || echo no)):"; cat "$LAB/a2.out"
echo "--- .watcher-down token: $(cat "$S/.watcher-down" 2>/dev/null || echo '<none>')"
closew
echo "--- fm-wake-drain.sh output:"; E "$R/bin/fm-wake-drain.sh" 2>/dev/null; echo "[drain exit=$? bytes above]"
if [ "$SC" = noready ]; then
  echo "--- after drain, ready marker: $(cat "$S/.branch-outcome-index-ready" 2>/dev/null || echo '<absent>')"
  arm "$LAB/a3.out"; closew0=1; arm_alive_wait=1
  echo "--- second re-arm after the healing drain:"; cat "$LAB/a3.out"; echo "(arm still alive=$(kill -0 $APID 2>/dev/null && echo yes || echo no))"
  sleep 3; echo "--- after 3s:"; cat "$LAB/a3.out"; echo "(arm still alive=$(kill -0 $APID 2>/dev/null && echo yes || echo no))"; closew
fi
rm -rf "$LAB"; echo
