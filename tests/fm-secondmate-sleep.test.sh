#!/usr/bin/env bash
# bin/fm-secondmate-sleep.sh: a second mate sleeps until it has work again, and
# one command wakes it.
#
# What these pin, all through the real commands (real fm-send, real durable
# steering inbox, real parent-owned reply expectation, real fm-control exit,
# real fm-spawn launch, real fm-teardown retirement) against a session-provider
# stub that models one agent's lifecycle in one tmux window:
#
#   1. Sleep persists first, then stops the agent and closes its endpoint, and
#      keeps this home's record, the mate's home, its backlog, and its route.
#   2. Sleep refuses, changing nothing, while the mate has work: work under way
#      in its home, an open request, or an unconfirmed persist.
#   3. While asleep nothing reaches or restarts it: a direct spawn or relaunch,
#      the control plane, a message, and a backlog handoff refuse with the wake
#      command, and the current-state and fleet reads say it is asleep. The
#      session-start sweep, the watcher tick, and the update pass are pinned in
#      their own suites.
#   4. Wake relaunches it through the normal spawn path in the same home and
#      clears the mark; a failed launch leaves it asleep.
#   5. Retirement of an asleep mate still works as retirement.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SLEEP_CMD="$ROOT/bin/fm-secondmate-sleep.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

fm_git_identity fmtest fmtest@example.com
TMP_ROOT=$(fm_test_tmproot fm-secondmate-sleep)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd -P)

# make_stub <case-dir>: one tmux window, fm-sm1, holding at most one agent.
# $D/windows is the session inventory, $D/command the window's foreground
# command. The harness exit command stops the agent, any other command typed
# into the bare shell starts one, kill-window closes the window, and new-window
# opens it again with a bare shell unless $D/fail-launch makes it fail. When armed, the live mate ANSWERS a
# doorbell by reporting on the parent channel with the correlation token the
# request carried - a real status append read by the real pending-reply code.
make_stub() {  # <case-dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
printf '%s\n' "$*" >> "$D/calls"
has_window() { grep -qx 'fm-sm1' "$D/windows" 2>/dev/null; }
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    [ "$literal" = 1 ] || { printf '%s\n' "$payload" >> "$D/keys"; exit 0; }
    printf '%s\n' "$payload" >> "$D/literal"
    case "$payload" in
      /exit|/quit) printf 'zsh' > "$D/command" ;;
      ': Firstmate instruction waiting: list '*)
        printf 'doorbell\n' >> "$D/rings"
        if [ -f "$D/answer-inbox" ]; then
          corr=$(cat "$(cat "$D/answer-inbox")"/*.msg 2>/dev/null \
            | grep -oE 'corr=[0-9a-f]{16}' | head -1)
          [ -z "$corr" ] || printf 'done [%s]: open records written down\n' "$corr" \
            >> "$(cat "$D/answer-status")"
        fi
        ;;
      *) [ "$(cat "$D/command")" != zsh ] || printf 'claude' > "$D/command" ;;
    esac
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) has_window || exit 1; cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
        *window_id*) printf '@1\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) printf 'main\n'; cat "$D/windows" 2>/dev/null; exit 0 ;;
  kill-window)
    : > "$D/windows"
    printf 'none' > "$D/command"
    exit 0 ;;
  new-window)
    [ ! -f "$D/fail-launch" ] || exit 1
    printf 'fm-sm1\n' > "$D/windows"
    printf 'zsh' > "$D/command"
    printf '@1\n'
    exit 0 ;;
  has-session) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
}

# new_case <name> -> a parent home holding one live local second mate, sm1, with
# its own seeded home, a registry route, and one queued item in its backlog.
new_case() {
  local dir="$TMP_ROOT/$1-$RANDOM" home smhome
  home="$dir/home"
  smhome="$dir/sm1-home"
  mkdir -p "$home/state" "$home/data/sm1" "$home/config" "$dir/fake" \
    "$smhome/bin" "$smhome/data" "$smhome/state" "$smhome/config" "$smhome/projects"
  touch "$home/state/.last-watcher-beat"
  printf 'claude\n' > "$home/config/secondmate-harness"
  printf 'claude\n' > "$home/config/crew-harness"
  printf '# charter\n' > "$home/data/sm1/brief.md"
  git init -q -b main "$smhome"
  printf 'sm1\n' > "$smhome/.fm-secondmate-home"
  printf '# Firstmate\n' > "$smhome/AGENTS.md"
  printf 'charter\n' > "$smhome/data/charter.md"
  printf '%s\n' 'projects/' 'state/' 'data/' 'config/' '.no-mistakes/' '.fm-secondmate-home' > "$smhome/.gitignore"
  printf '# Backlog\n\n## Queued\n\n- [ ] sm1-task - a queued item the mate owns\n' > "$smhome/data/backlog.md"
  printf -- '- sm1 - Test second mate. (home: %s; scope: test work; projects: none; added 2026-10-29)\n' \
    "$smhome" > "$home/data/secondmates.md"
  {
    echo "window=firstmate:fm-sm1"
    echo "endpoint_task_id=sm1"
    echo "worktree=$smhome"
    echo "project=$smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=default"
    echo "effort=default"
    echo "spawn_gen=s1.1.1"
    echo "home=$smhome"
    echo "projects="
  } > "$home/state/sm1.meta"
  printf 'fm-sm1\n' > "$dir/fake/windows"
  printf 'claude' > "$dir/fake/command"
  printf '%s' "$smhome" > "$dir/fake/cwd"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  : > "$dir/fake/rings"
  : > "$dir/fake/calls"
  make_stub "$dir"
  printf '%s\n' "$dir"
}

# arm_answer <case-dir>: make the modelled mate answer the persist request.
arm_answer() {
  local dir=$1
  printf '%s' "$dir/home/state/sm1.inbox" > "$dir/fake/answer-inbox"
  printf '%s' "$dir/home/state/sm1.status" > "$dir/fake/answer-status"
}

# in_case <case-dir> <command...>: run a real command against the case's home.
in_case() {
  local dir=$1; shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    TMUX='' FM_BACKEND=tmux FM_SPAWN_NO_GUARD=1 \
    FM_SECONDMATE_PERSIST_POLL=1 FM_SECONDMATE_PERSIST_WAIT="${FM_TEST_PERSIST_WAIT:-30}" \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.5 FM_CONTROL_LAUNCH_WAIT=0.5 \
    "$@" 2>&1
}

sleep_mate() {  # <case-dir>
  in_case "$1" "$SLEEP_CMD" sleep sm1
}

wake_mate() {  # <case-dir>
  in_case "$1" "$SLEEP_CMD" wake sm1
}

asleep_line() {  # <case-dir>
  grep '^asleep=' "$1/home/state/sm1.meta" 2>/dev/null || true
}

# --- T1: sleep persists, stops, closes, and keeps everything else ------------
test_sleep_persists_then_stops_and_keeps_records() {
  local dir out rc doorbell_line exit_line route_before backlog_before
  dir=$(new_case sleep)
  arm_answer "$dir"
  route_before=$(cat "$dir/home/data/secondmates.md")
  backlog_before=$(cat "$dir/sm1-home/data/backlog.md")

  out=$(sleep_mate "$dir"); rc=$?

  expect_code 0 "$rc" "a mate with no work should go to sleep"$'\n'"$out"
  assert_contains "$out" "asleep: sm1 since" "sleep should report the new state"
  assert_contains "$out" "bin/fm-secondmate-sleep.sh wake sm1" "sleep should name the wake command"
  doorbell_line=$(grep -n '^: Firstmate instruction waiting: ' "$dir/fake/literal" | head -1 | cut -d: -f1)
  exit_line=$(grep -n '^/exit$' "$dir/fake/literal" | head -1 | cut -d: -f1)
  [ -n "$doorbell_line" ] || fail "the persist request never reached the mate"
  [ -n "$exit_line" ] || fail "the mate's agent was never stopped"
  [ "$doorbell_line" -lt "$exit_line" ] \
    || fail "the agent was stopped before it was asked to persist (persist line $doorbell_line, exit line $exit_line)"
  assert_contains "$(cat "$dir/home/state/sm1.inbox"/*.msg)" "put you to sleep" \
    "the persist request must say why the conversation is being spent"
  assert_contains "$(cat "$dir/home/state/sm1.inbox"/*.msg)" "Open-record persistence" \
    "the persist request must reuse stow's open-record contract"
  assert_grep 'kill-window -t =firstmate:=fm-sm1' "$dir/fake/calls" "the mate's endpoint was not closed"
  [ ! -s "$dir/fake/windows" ] || fail "the mate's window is still open"
  [ -n "$(asleep_line "$dir")" ] || fail "the task record was not marked asleep"
  grep -qx 'spawn_gen=s1.1.1' "$dir/home/state/sm1.meta" || fail "the task record lost its fields"
  grep -qxF "home=$dir/sm1-home" "$dir/home/state/sm1.meta" || fail "the task record lost its home"
  [ "$(cat "$dir/home/data/secondmates.md")" = "$route_before" ] || fail "sleep changed the registry route"
  [ "$(cat "$dir/sm1-home/data/backlog.md")" = "$backlog_before" ] || fail "sleep changed the mate's backlog"
  assert_present "$dir/sm1-home/data/charter.md" "sleep removed the mate's home records"
  grep -h '^phase=' "$dir/home/state/pending-replies"/* | grep -q '^phase=resolved$' \
    || fail "the persist answer did not settle its durable expectation"

  out=$(sleep_mate "$dir"); rc=$?
  expect_code 0 "$rc" "sleeping an asleep mate should be a no-op"$'\n'"$out"
  assert_contains "$out" "nothing changed" "a repeated sleep should say nothing changed"
  [ "$(grep -c '^/exit$' "$dir/fake/literal")" -eq 1 ] || fail "a repeated sleep stopped something again"
  pass "T1 sleep persists first, stops the agent, closes the endpoint, and keeps every record"
}

# --- T2: sleep refuses while the mate has work ------------------------------
test_sleep_refuses_while_the_mate_has_work() {
  local dir out rc
  dir=$(new_case busy-child)
  arm_answer "$dir"
  printf 'window=firstmate:fm-child\nkind=ship\n' > "$dir/sm1-home/state/child.meta"
  out=$(sleep_mate "$dir"); rc=$?
  expect_code 1 "$rc" "a mate with work under way must not sleep"$'\n'"$out"
  assert_contains "$out" "work under way in its home (child.meta)" "the refusal must name the work"
  assert_no_grep '/exit' "$dir/fake/literal" "a refused sleep stopped the agent"
  [ -z "$(asleep_line "$dir")" ] || fail "a refused sleep marked the mate asleep"
  assert_no_grep ': Firstmate instruction waiting: ' "$dir/fake/literal" "a refused sleep asked the mate to persist"

  dir=$(new_case unconfirmed)
  out=$(FM_TEST_PERSIST_WAIT=0 sleep_mate "$dir"); rc=$?
  expect_code 1 "$rc" "an unconfirmed persist must not stop the agent"$'\n'"$out"
  assert_contains "$out" "did not confirm within 0s that its open work is written down" \
    "the refusal must name the missing confirmation"
  assert_contains "$out" "Its agent was left running" "the refusal must say the agent still runs"
  assert_no_grep '/exit' "$dir/fake/literal" "an unconfirmed persist stopped the agent"
  [ -z "$(asleep_line "$dir")" ] || fail "an unconfirmed persist marked the mate asleep"

  # That unanswered request is now an open request from this home, which a
  # second attempt must also respect until the mate answers it.
  out=$(sleep_mate "$dir"); rc=$?
  expect_code 1 "$rc" "a mate owing a reply must not sleep"$'\n'"$out"
  assert_contains "$out" "still owes a reply to an open request" "the refusal must name the open request"
  assert_no_grep '/exit' "$dir/fake/literal" "a refused sleep stopped the agent"
  pass "T2 sleep refuses, changing nothing, while the mate has work or has not confirmed its records"
}

# put_to_sleep <case-dir>: a case whose mate has just been put to sleep.
put_to_sleep() {
  local dir=$1 out
  arm_answer "$dir"
  out=$(sleep_mate "$dir") || fail "the fixture mate could not be put to sleep: $out"
  : > "$dir/fake/calls"
  : > "$dir/fake/literal"
}

# --- T3: while asleep, nothing reaches it or brings it back ------------------
test_asleep_mate_is_left_alone() {
  local dir out rc meta_before verb
  dir=$(new_case asleep)
  put_to_sleep "$dir"
  meta_before=$(cat "$dir/home/state/sm1.meta")

  out=$(in_case "$dir" "$ROOT/bin/fm-spawn.sh" sm1 --secondmate); rc=$?
  expect_code 1 "$rc" "a direct spawn must not bring an asleep mate back"$'\n'"$out"
  assert_contains "$out" "second mate sm1 is asleep; wake it first with bin/fm-secondmate-sleep.sh wake sm1" \
    "the spawn refusal must name the wake command"
  out=$(in_case "$dir" "$ROOT/bin/fm-spawn.sh" sm1 --relaunch); rc=$?
  expect_code 1 "$rc" "a relaunch must not bring an asleep mate back"$'\n'"$out"
  assert_contains "$out" "bin/fm-secondmate-sleep.sh wake sm1" "the relaunch refusal must name the wake command"
  out=$(FM_SECONDMATE_WAKE=sm1 in_case "$dir" "$ROOT/bin/fm-spawn.sh" sm1 --relaunch); rc=$?
  expect_code 1 "$rc" "the wake authorization must not extend to a relaunch"$'\n'"$out"

  for verb in interrupt exit relaunch; do
    out=$(in_case "$dir" "$ROOT/bin/fm-control.sh" sm1 "$verb"); rc=$?
    expect_code 1 "$rc" "the control plane must not $verb an asleep mate"$'\n'"$out"
    assert_contains "$out" "second mate sm1 is asleep; wake it first with bin/fm-secondmate-sleep.sh wake sm1" \
      "the control-plane refusal must name the wake command"
  done

  out=$(in_case "$dir" "$ROOT/bin/fm-send.sh" sm1 "new work for you"); rc=$?
  expect_code 1 "$rc" "a message to an asleep mate must be refused"$'\n'"$out"
  assert_contains "$out" "second mate sm1 is asleep; wake it first with bin/fm-secondmate-sleep.sh wake sm1; nothing was sent" \
    "the routing refusal must be plain and name the wake command"
  [ ! -d "$dir/home/state/sm1.inbox" ] || [ "$(find "$dir/home/state/sm1.inbox" -maxdepth 1 -name '*.msg' -newer "$dir/home/state/sm1.meta" | wc -l | tr -d ' ')" -eq 0 ] \
    || fail "a refused message was still recorded in the mate's inbox"

  printf '# Backlog\n\n## Queued\n\n- [ ] new-work - an item for the mate\n' > "$dir/home/data/backlog.md"
  out=$(in_case "$dir" "$ROOT/bin/fm-backlog-handoff.sh" sm1 new-work); rc=$?
  expect_code 1 "$rc" "a handoff to an asleep mate must be refused"$'\n'"$out"
  assert_contains "$out" "wake it first with bin/fm-secondmate-sleep.sh wake sm1; no backlog item was moved" \
    "the handoff refusal must name the wake command"
  assert_grep 'new-work' "$dir/home/data/backlog.md" "a refused handoff moved the item anyway"

  out=$(in_case "$dir" "$ROOT/bin/fm-crew-state.sh" sm1); rc=$?
  expect_code 0 "$rc" "the current-state read should succeed"$'\n'"$out"
  assert_contains "$out" "state: paused" "an asleep mate should read as a declared wait, not a gone endpoint"
  assert_contains "$out" "asleep since" "the current-state read should say the mate is asleep"
  assert_contains "$out" "wake with bin/fm-secondmate-sleep.sh wake sm1" "the current-state read should name the wake command"

  out=$(in_case "$dir" "$ROOT/bin/fm-fleet-snapshot.sh" --json); rc=$?
  expect_code 0 "$rc" "the fleet snapshot should read an asleep mate"$'\n'"$out"
  [ "$(printf '%s\n' "$out" | jq -r '.tasks[] | select(.id == "sm1") | .endpoint.status')" = asleep ] \
    || fail "the fleet snapshot did not report the closed endpoint as asleep: $out"

  [ "$(cat "$dir/home/state/sm1.meta")" = "$meta_before" ] || fail "a refused path changed the asleep record"
  assert_no_grep 'new-window' "$dir/fake/calls" "something reopened the asleep mate's endpoint"
  pass "T3 while asleep, spawn, control, messages, and handoffs refuse with the wake command, and status reads say asleep"
}

# --- T4: wake relaunches it in the same home and clears the mark --------------
test_wake_relaunches_in_the_same_home() {
  local dir out rc
  dir=$(new_case wake)
  put_to_sleep "$dir"

  touch "$dir/fake/fail-launch"
  out=$(wake_mate "$dir"); rc=$?
  expect_code 1 "$rc" "a launch that never comes up must not report the mate awake"$'\n'"$out"
  assert_contains "$out" "stays asleep" "a failed wake must leave the mate asleep"
  [ -n "$(asleep_line "$dir")" ] || fail "a failed wake lost the asleep mark"
  grep -qxF "home=$dir/sm1-home" "$dir/home/state/sm1.meta" || fail "a failed wake lost the mate's record"
  rm -f "$dir/fake/fail-launch"
  : > "$dir/fake/calls"

  out=$(wake_mate "$dir"); rc=$?
  expect_code 0 "$rc" "wake should bring the mate back"$'\n'"$out"
  assert_contains "$out" "awake: sm1 relaunched in its own home" "wake should report the relaunch"
  assert_grep 'new-window' "$dir/fake/calls" "wake did not open a new endpoint"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "wake did not start an agent"
  [ -z "$(asleep_line "$dir")" ] || fail "wake did not clear the asleep mark"
  grep -qx 'kind=secondmate' "$dir/home/state/sm1.meta" || fail "the woken record is not a second mate's"
  grep -qxF "home=$dir/sm1-home" "$dir/home/state/sm1.meta" || fail "the mate did not wake in its own home"
  out=$(wake_mate "$dir"); rc=$?
  expect_code 0 "$rc" "waking an awake mate should be a no-op"$'\n'"$out"
  assert_contains "$out" "is not asleep; nothing changed" "a repeated wake should say nothing changed"
  pass "T4 wake relaunches the mate in its own home through the normal spawn path and clears the mark"
}

# --- T5: an asleep mate still retires -----------------------------------------
test_asleep_mate_retires() {
  local dir out rc
  dir=$(new_case retire)
  put_to_sleep "$dir"

  out=$(in_case "$dir" "$ROOT/bin/fm-teardown.sh" sm1); rc=$?
  expect_code 0 "$rc" "an asleep mate should still retire"$'\n'"$out"
  assert_absent "$dir/home/state/sm1.meta" "retirement left the asleep record behind"
  assert_no_grep 'sm1' "$dir/home/data/secondmates.md" "retirement left the route behind"
  assert_absent "$dir/sm1-home" "retirement left the mate's home behind"
  out=$(wake_mate "$dir"); rc=$?
  expect_code 1 "$rc" "a retired mate cannot be woken"$'\n'"$out"
  pass "T5 retiring an asleep mate removes its record, route, and home exactly as retirement does"
}

test_sleep_persists_then_stops_and_keeps_records
test_sleep_refuses_while_the_mate_has_work
test_asleep_mate_is_left_alone
test_wake_relaunches_in_the_same_home
test_asleep_mate_retires

echo "# all fm-secondmate-sleep tests passed"
