#!/usr/bin/env bash
# Live driver: real worker + heartbeat, ready file corrupted to a foreign/dead pid.
set -u
ROOT=$1
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-hb.XXXXXX"); W=$(cd "$W" && pwd -P)
mkdir -p "$W/remote-root/bin" "$W/account" "$W/home"
cp "$ROOT/bin/fm-remote-job-lib.sh" "$ROOT/bin/fm-remote-job-worker.sh" "$ROOT/bin/fm-remote-delta-read.sh" "$W/remote-root/bin/"
printf 'fixture\n' > "$W/remote-root/AGENTS.md"
export FM_REMOTE_JOB_STATE_ROOT="$W/state" FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_QUEUE_TIMEOUT=5 FM_REMOTE_JOB_TIMEOUT=5
. "$ROOT/bin/fm-remote-job-lib.sh"
cleanup() { [ -f "$W/state/worker.pid" ] && fm_remote_job_stop_worker_tree "$(cat "$W/state/worker.pid")"; rm -rf "$W"; }
trap cleanup EXIT
fm_remote_job_ensure_worker "$W/remote-root" "$W/account" || { echo "FAIL start: $FM_REMOTE_JOB_ERROR"; exit 1; }
P=$(cat "$W/state/worker.pid"); echo "worker.pid=$P ready=$(cat "$W/state/worker.ready")"
for bogus in 999999 "$$"; do
  printf '%s\n' "$bogus" > "$W/state/worker.ready"
  echo "corrupted worker.ready -> $(cat "$W/state/worker.ready")"
  if fm_remote_job_ready_owner_live "$W/account"; then echo "  ready_owner_live (before heal): yes"; else echo "  ready_owner_live (before heal): no"; fi
  healed=
  for i in $(seq 1 40); do [ "$(cat "$W/state/worker.ready")" = "$P" ] && { healed=$i; break; }; sleep 0.1; done
  [ -n "$healed" ] || { echo "FAIL heartbeat never rewrote ready (content=$(cat "$W/state/worker.ready"))"; exit 1; }
  echo "  heartbeat rewrote worker.ready to $P after ~$((healed*100))ms; mode=$(stat -f %Lp "$W/state/worker.ready" 2>/dev/null || stat -c %a "$W/state/worker.ready")"
  fm_remote_job_ensure_worker "$W/remote-root" "$W/account" || { echo "FAIL ensure after heal: $FM_REMOTE_JOB_ERROR"; exit 1; }
  [ "$(cat "$W/state/worker.pid")" = "$P" ] || { echo "FAIL ensure restarted a healthy worker"; exit 1; }
  echo "  ensure_worker: ok, same live worker kept ($P)"
done
# matching content: only mtime refresh, content stays
m1=$(stat -f %m "$W/state/worker.ready" 2>/dev/null || stat -c %Y "$W/state/worker.ready"); sleep 2.2
m2=$(stat -f %m "$W/state/worker.ready" 2>/dev/null || stat -c %Y "$W/state/worker.ready")
echo "matching ready keeps content=$(cat "$W/state/worker.ready"), mtime advanced $m1 -> $m2"
[ "$m2" -gt "$m1" ] || { echo "FAIL no refresh"; exit 1; }
echo "PASS"
