#!/usr/bin/env bash
# A watcher must discard observations whose task is retired during its scan.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-retired)
WATCH="$ROOT/bin/fm-watch.sh"

test_retired_signal() {
  local dir state fakebin pid i
  dir=$(make_case retired-signal); state="$dir/state"; fakebin="$dir/fakebin"
  fm_write_meta "$state/task.meta" 'window=sess:fm-task' 'backend=tmux'
  printf 'done: landed\n' > "$state/task.status"
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
if [ "$1" = 7 ]; then
  touch "$FM_RETIRE_STATE/grace-started"
  while [ ! -f "$FM_RETIRE_STATE/retired" ]; do /bin/sleep 0.1; done
else
  /bin/sleep "$@"
fi
SH
  chmod +x "$fakebin/sleep"
  PATH="$fakebin:$PATH" FM_RETIRE_STATE="$state" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=7 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
    "$WATCH" > "$dir/out" 2> "$dir/err" &
  pid=$!
  for ((i=0; i<200; i++)); do
    [ ! -f "$state/grace-started" ] || break
    /bin/sleep 0.1
  done
  [ -f "$state/grace-started" ] || fail 'watcher never observed the live task signal'
  # The endpoint and records are gone, as after successful teardown.
  rm "$state/task.meta" "$state/task.status"
  touch "$state/retired"
  /bin/sleep 3
  if ! kill -0 "$pid" 2>/dev/null; then
    cat "$dir/out" >&2
    fail 'watcher surfaced a signal for the retired task'
  fi
  kill "$pid"; wait "$pid" 2>/dev/null || true
  [ ! -s "$state/.wake-queue" ] || fail 'retired task left a queued wake'
  pass 'signal grace discards a task retired after the initial scan'
}

test_retired_stale() {
  local dir state fakebin pid i
  dir=$(make_case retired-stale); state="$dir/state"; fakebin="$dir/fakebin"
  fm_write_meta "$state/task.meta" 'window=sess:fm-task' 'backend=tmux'
  # Seed two identical empty captures so the next capture is stale.
  printf '%s\n' d41d8cd98f00b204e9800998ecf8427e > "$state/.hash-sess_fm-task"
  printf '2\n' > "$state/.count-sess_fm-task"
  mv "$fakebin/tmux" "$fakebin/tmux-original"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "$1" = capture-pane ]; then
  rm -f "$FM_RETIRE_STATE/task.meta"
  touch "$FM_RETIRE_STATE/retired"
fi
exec "$(dirname "$0")/tmux-original" "$@"
SH
  chmod +x "$fakebin/tmux"
  PATH="$fakebin:$PATH" FM_RETIRE_STATE="$state" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
    "$WATCH" > "$dir/out" 2> "$dir/err" &
  pid=$!
  for ((i=0; i<200; i++)); do
    [ ! -f "$state/retired" ] || break
    /bin/sleep 0.1
  done
  [ -f "$state/retired" ] || fail 'watcher never captured the task pane'
  /bin/sleep 3
  if ! kill -0 "$pid" 2>/dev/null; then
    cat "$dir/out" >&2
    fail 'watcher surfaced stale for a task retired during capture'
  fi
  kill "$pid"; wait "$pid" 2>/dev/null || true
  [ ! -s "$state/.wake-queue" ] || fail 'retired pane left a queued wake'
  pass 'pane scan discards a task retired during capture'
}

test_live_task() {
  local mode=$1 dir state fakebin pid i
  dir=$(make_case "live-$mode"); state="$dir/state"; fakebin="$dir/fakebin"
  fm_write_meta "$state/task.meta" 'window=sess:fm-task' 'backend=tmux'
  if [ "$mode" = signal ]; then
    printf 'done: landed\n' > "$state/task.status"
  else
    printf '%s\n' d41d8cd98f00b204e9800998ecf8427e > "$state/.hash-sess_fm-task"
    printf '2\n' > "$state/.count-sess_fm-task"
  fi
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" \
    FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
    "$WATCH" > "$dir/out" 2> "$dir/err" &
  pid=$!
  for ((i=0; i<200; i++)); do
    kill -0 "$pid" 2>/dev/null || break
    /bin/sleep 0.1
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid"; wait "$pid" 2>/dev/null || true
    fail "live task never surfaced $mode"
  fi
  wait "$pid" || fail "live task watcher failed"
  grep -q "^$mode:" "$dir/out" || fail "missing live task $mode reason"
  grep -q "$(printf '\t')$mode$(printf '\t')" "$state/.wake-queue" \
    || fail "missing queued live task $mode"
  pass "live task still surfaces $mode"
}

test_retired_stale
test_retired_signal
test_live_task stale
test_live_task signal
