#!/usr/bin/env bash
# Live drive: real fm-watch.sh + real fm-teardown.sh on a private lab tmux server.
set -u
W=${FM_DRIVE_ROOT:-/Users/owlshome/.no-mistakes/worktrees/5e738cfca1e1/01M64NA628KDDXGXX9AWFXRT2F}
cd "$W"
MODE=$1   # teardown | control
LAB=$(cd "$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX")" && pwd -P)
bin/fm-lab-home.sh create "$LAB" >/dev/null || exit 1
TD=$(bin/fm-lab-home.sh tmux-dir "$LAB")
t() { env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$TD" tmux -L fm-lab "$@"; }
cleanup() { t kill-server 2>/dev/null; bin/fm-lab-home.sh teardown "$LAB" >/dev/null 2>&1; git -C "$LAB/projects/demo" worktree prune 2>/dev/null; rm -rf "$LAB"; }
trap cleanup EXIT
git init -q "$LAB/projects/demo"
git -C "$LAB/projects/demo" -c user.name=t -c user.email=t@e.invalid commit --allow-empty -qm init
mkdir -p "$LAB/scratch"  
t new-session -d -s lab -n fm-scout1 -c "$LAB/scratch" -e FM_HOME="$LAB" 'bash --norc'
cat > "$LAB/state/scout1.meta" <<EOF
window=lab:fm-scout1
endpoint_task_id=scout1
backend=tmux
kind=scout
worktree=$LAB/wt-scout1
project=$LAB/projects/demo
EOF
t send-keys -t lab:fm-scout1 'while :; do date +%s.%N; sleep 1; done' Enter
echo "== lab $LAB; windows:"; t list-windows -a -F '#{session_name}:#{window_name} pane=#{pane_id}'
echo "== meta:"; cat "$LAB/state/scout1.meta"
t new-window -d -t lab -n watcher -c "$W" -e FM_HOME="$LAB" "FM_POLL=2 FM_SIGNAL_GRACE=15 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 bin/fm-watch.sh > $LAB/watch.out 2> $LAB/watch.err; echo watcher-exit=\$? >> $LAB/watch.out; sleep 600"
sleep 6
echo "== $(date +%T) watcher running, stale count=$(cat "$LAB/state/.count-lab_fm-scout1" 2>/dev/null); output so far: [$(cat "$LAB/watch.out")]"
printf 'done: scout report landed\n' > "$LAB/state/scout1.status"
echo "== $(date +%T) worker wrote done status"
sleep 4
if [ "$MODE" = teardown ]; then
  echo "== $(date +%T) running bin/fm-teardown.sh scout1 --force (inside lab, during the 15s signal grace)"
  t new-window -d -t lab -n td -c "$W" -e FM_HOME="$LAB" "bin/fm-teardown.sh scout1 --force > $LAB/td.out 2>&1; echo teardown-exit=\$? >> $LAB/td.out"
  for i in $(seq 1 60); do grep -q teardown-exit "$LAB/td.out" 2>/dev/null && break; sleep 0.5; done
  echo "== teardown output:"; cat "$LAB/td.out"
  echo "== windows after teardown:"; t list-windows -a -F '#{session_name}:#{window_name}'
  echo "== state after teardown:"; ls -a "$LAB/state" | grep -E 'scout1|wake' || echo "(no scout1 records, no wake queue)"
  echo "== $(date +%T) observing watcher for 30s (grace expiry + ~13 polls)"
  sleep 30
else
  sleep 20
fi
echo "== $(date +%T) watcher output: [$(cat "$LAB/watch.out")]"
echo "== watcher alive: $(pgrep -f "FM_HOME=$LAB" >/dev/null; t list-panes -t lab:watcher -F '#{pane_current_command}' 2>/dev/null)"
echo "== wake queue:"; cat "$LAB/state/.wake-queue" 2>/dev/null || echo "(empty / absent)"
echo "== hash/count files for the old pane:"; ls -a "$LAB/state" | grep -E 'hash|count' || echo "(none)"
