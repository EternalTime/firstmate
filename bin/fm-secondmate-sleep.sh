#!/usr/bin/env bash
# fm-secondmate-sleep.sh - put a persistent second mate to sleep until it has
# work again, and wake it with one command.
#
# Usage: fm-secondmate-sleep.sh sleep <id>
#        fm-secondmate-sleep.sh wake <id>
#        fm-secondmate-sleep.sh --help
#
# Sleep is the reversible middle between a running mate and a retired one. It
# stops the mate's agent and closes its endpoint, so the mate costs nothing,
# and it keeps everything else exactly where it is: this home's task record,
# the mate's own home with every record and its backlog, its lease, and its
# data/secondmates.md route. The task record then carries the asleep mark that
# bin/fm-secondmate-sleep-lib.sh owns, and every automatic path that would
# otherwise restart, nudge, message, or alert on the mate steps aside for it, so
# nothing brings it back until it is woken. Retirement keeps its own meaning and
# owner: bin/fm-teardown.sh retires an asleep mate exactly as it retires an
# awake one.
#
#   sleep  Refuses, changing nothing, while the mate still has work under way in
#          its own home, owes a reply to an open request from this home, or has
#          handed-off work it has not yet been told about - each of those is
#          work, and sleep is for a mate that has none. A running agent first
#          gets the same persist gate as a restart: one marked request to write
#          down the open work it holds only in its conversation, following the
#          /stow skill's "Open-record persistence" section
#          (bin/fm-secondmate-restart-lib.sh owns that instruction), and nothing
#          is stopped until that mate's own correlated answer lands on the parent
#          channel and the turn that carried it has finished, because the
#          answer lands before the reply does and a stop mid-reply would
#          interrupt it. A retried sleep reuses an answer this same agent gave
#          within FM_SECONDMATE_PERSIST_REUSE seconds when no other message has
#          reached it since, rather than asking again. The agent is then
#          stopped through the control plane's
#          verified exit (bin/fm-control.sh <id> exit), its endpoint is closed,
#          and the asleep mark is published into the task record. An agent that
#          is already stopped has no conversation left to persist and skips
#          straight to closing what remains of its endpoint.
#   wake   Relaunches the mate in the same home through the ordinary
#          bin/fm-spawn.sh <id> --secondmate path every respawn uses, which
#          re-resolves its configured harness, syncs the home, re-propagates
#          inherited local material, and republishes the task record without
#          the mark. The woken mate runs its own session start, so it reconciles
#          its own records and picks up where they say it left off. A launch
#          that fails leaves the mate asleep, restoring its record when the
#          failed launch removed it.
#
# Both verbs are idempotent: sleeping an asleep mate and waking an awake one
# report that state and change nothing.
#
# A remotely placed second mate is refused by name: its agent runs on another
# host, where this home can neither stop it with a verified postcondition nor
# close its endpoint.
#
# Serialization: both verbs hold the mate's liveness lock
# (bin/fm-secondmate-liveness-lib.sh) from the first check to the last write,
# so neither the session-start sweep nor the watcher can relaunch a mate whose
# agent has just been stopped, and bin/fm-teardown.sh, which takes the same lock
# for a second mate, cannot retire one mid-transition. Sleep publishes the mark
# only after the agent is stopped: an interrupted sleep can therefore leave at
# worst a stopped, unmarked mate, which ordinary recovery relaunches, and never
# a running mate nothing supervises.
#
# Environment knobs:
#   FM_SECONDMATE_PERSIST_WAIT  seconds to wait for the persist answer (shared
#                               with restart) and, here, its turn to end (900)
#   FM_SECONDMATE_PERSIST_POLL  seconds between checks of that answer (5)
#   FM_SECONDMATE_PERSIST_REUSE seconds a persist answer stays reusable by a
#                               retried sleep when nothing reached the mate
#                               since (900)
#
# Exit status: 0 the mate is now in the requested state (or already was);
# 1 refused or failed, with the outcome stated; 2 invalid use; 4 the mate is
# asleep, but its endpoint could not be confirmed closed and is named for
# closing by hand.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,75{s/^# \{0,1\}//;p;}' "$0"
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  sleep|wake) ;;
  *) usage >&2; exit 2 ;;
esac
VERB=$1
[ "$#" -eq 2 ] || { usage >&2; exit 2; }
ID=$2
case "$ID" in ''|.*|*[!A-Za-z0-9._-]*) echo "error: invalid second mate id: $ID" >&2; exit 2 ;; esac

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# Fail closed before any fleet mutation: a no-mistakes gate agent must never
# drive a second mate's lifecycle (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent

if [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-secondmate-sleep refuses to resolve a second mate without an explicit firstmate home" >&2
  exit 1
fi
[ -d "$FM_HOME" ] || { echo "error: FM_HOME '$FM_HOME' is not a directory" >&2; exit 1; }
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
[ -d "$STATE" ] || { echo "error: state dir '$STATE' is missing; fm-secondmate-sleep cannot resolve second mates for FM_HOME '$FM_HOME'" >&2; exit 1; }

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"
# shellcheck source=bin/fm-secondmate-restart-lib.sh
. "$SCRIPT_DIR/fm-secondmate-restart-lib.sh"
# shellcheck source=bin/fm-secondmate-sleep-lib.sh
. "$SCRIPT_DIR/fm-secondmate-sleep-lib.sh"
# Role partition: a second mate's lifecycle is main's alone, like its
# retirement (bin/fm-lease-lib.sh; a no-op in homes without a supervision branch).
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_forbid_branch "second mate $VERB (fm-secondmate-sleep)"

PERSIST_WAIT=${FM_SECONDMATE_PERSIST_WAIT:-900}
PERSIST_POLL=${FM_SECONDMATE_PERSIST_POLL:-5}
PERSIST_REUSE=${FM_SECONDMATE_PERSIST_REUSE:-900}
case "$PERSIST_WAIT" in ''|*[!0-9]*) echo "error: FM_SECONDMATE_PERSIST_WAIT must be a non-negative integer: $PERSIST_WAIT" >&2; exit 2 ;; esac
case "$PERSIST_POLL" in ''|*[!0-9]*|0) echo "error: FM_SECONDMATE_PERSIST_POLL must be a positive integer: $PERSIST_POLL" >&2; exit 2 ;; esac
case "$PERSIST_REUSE" in ''|*[!0-9]*) echo "error: FM_SECONDMATE_PERSIST_REUSE must be a non-negative integer: $PERSIST_REUSE" >&2; exit 2 ;; esac

META="$STATE/$ID.meta"
WAKE_CMD=$(fm_secondmate_wake_command "$ID")

# Why the mate's conversation is about to be spent, ahead of the shared ask.
SLEEP_PERSIST_REQUEST="I am about to put you to sleep until there is work for you again: your agent will be stopped and its terminal closed, which drops your conversation but keeps your home, every durable record, and your backlog exactly as they are, and waking you later starts a new agent in this same home. $FM_SECONDMATE_PERSIST_INSTRUCTION"

LIVENESS_LOCK="$STATE/.secondmate-liveness-$ID.lock"
LIVENESS_LOCK_HELD=0
CONTROL_LOCK="$STATE/.control-$ID.lock"
CONTROL_LOCK_HELD=0
META_LOCK=
META_LOCK_HELD=0
SCRATCH=
release_all() {
  if [ "$META_LOCK_HELD" = 1 ]; then
    META_LOCK_HELD=0
    fm_lock_release "$META_LOCK" || true
  fi
  if [ "$CONTROL_LOCK_HELD" = 1 ]; then
    CONTROL_LOCK_HELD=0
    fm_lock_release "$CONTROL_LOCK" || true
  fi
  if [ "$LIVENESS_LOCK_HELD" = 1 ]; then
    LIVENESS_LOCK_HELD=0
    fm_lock_release "$LIVENESS_LOCK" || true
  fi
  [ -z "$SCRATCH" ] || rm -f -- "$SCRATCH"
}
trap release_all EXIT
trap 'release_all; exit 130' INT TERM

die() {  # <message>
  echo "error: $1" >&2
  exit 1
}

# A command's own reason for failing, flattened to one readable line: its last
# "error: " line when it printed one (warnings often come first), else its
# first line that carries anything.
reported_reason() {  # <text>
  local reason
  reason=$(printf '%s\n' "$1" | sed -n 's/^error: //p' | tail -1)
  [ -n "$reason" ] || reason=$(printf '%s\n' "$1" | sed -n '/./{p;q;}')
  printf '%s\n' "${reason:-no reason was reported}" | sed 's/[[:space:]]\{1,\}/ /g'
}

require_secondmate_record() {
  [ -f "$META" ] && [ ! -L "$META" ] \
    || die "no second mate $ID is recorded in this home ($META is missing or not a regular file)"
  [ "$(fm_meta_get "$META" kind)" = secondmate ] \
    || die "task $ID is not a second mate; sleep and wake apply only to persistent second mates"
  if [ -n "$(fm_meta_get "$META" remote_host)" ]; then
    die "second mate $ID is placed remotely on $(fm_meta_get "$META" remote_host); its agent runs on another host, where this home can neither prove it stopped nor close its endpoint, so it cannot be put to sleep or woken from here"
  fi
}

take_liveness_lock() {
  fm_lock_try_acquire "$LIVENESS_LOCK" \
    || die "a liveness check, relaunch, or retirement is already in progress for second mate $ID; nothing was changed - retry shortly"
  LIVENESS_LOCK_HELD=1
}

ENDPOINT_BACKEND=
ENDPOINT_TARGET=
ENDPOINT_STATE=
# The recorded endpoint and its recovery-grade agent state. A record that names
# no endpoint has no agent and nothing to close, which reads as missing.
read_endpoint() {
  ENDPOINT_BACKEND=$(fm_backend_of_meta "$META")
  ENDPOINT_TARGET=$(fm_backend_target_of_meta "$META")
  [ -n "$ENDPOINT_TARGET" ] || ENDPOINT_TARGET=$(fm_meta_get "$META" window)
  if [ -z "$ENDPOINT_TARGET" ]; then
    ENDPOINT_STATE=missing
    return 0
  fi
  ENDPOINT_STATE=$(fm_backend_agent_state "$ENDPOINT_BACKEND" "$ENDPOINT_TARGET" 2>/dev/null) \
    || ENDPOINT_STATE=unreadable
}

# Close what remains of the recorded endpoint with the same per-backend close
# retirement uses, then report whether it now reads gone.
close_endpoint() {
  [ "$ENDPOINT_STATE" != missing ] || return 0
  fm_backend_kill "$ENDPOINT_BACKEND" "$ENDPOINT_TARGET" \
    "$(fm_meta_get "$META" zellij_tab_id)" "fm-$ID" >/dev/null 2>&1 || true
  read_endpoint
  [ "$ENDPOINT_STATE" = missing ]
}

# Print the newest sleep persist answer this incarnation of the mate gave within
# PERSIST_REUSE seconds, when no other message has reached it since that request
# was delivered; print nothing otherwise. A sleep whose stop step refused after
# the mate answered can then be retried without asking it again.
reusable_persist_answer() {
  local spawn_epoch now rec corr delivered resolved best='' best_at=0 msg seq n
  spawn_epoch=$(fm_meta_get "$META" spawn_gen)
  spawn_epoch=${spawn_epoch#s}
  spawn_epoch=${spawn_epoch%%.*}
  case "$spawn_epoch" in ''|*[!0-9]*) return 0 ;; esac
  now=$(date +%s)
  for rec in "$(fm_pending_reply_dir "$STATE")"/*; do
    [ -f "$rec" ] && [ ! -L "$rec" ] || continue
    [ "$(fm_pending_reply_get "$rec" task_id)" = "$ID" ] || continue
    [ "$(fm_pending_reply_get "$rec" phase)" = resolved ] || continue
    case "$(fm_pending_reply_get "$rec" request_summary)" in
      "${SLEEP_PERSIST_REQUEST:0:60}"*) ;;
      *) continue ;;
    esac
    delivered=$(fm_pending_reply_get "$rec" delivered_epoch)
    resolved=$(fm_pending_reply_get "$rec" resolved_epoch)
    case "$delivered$resolved" in ''|*[!0-9]*) continue ;; esac
    [ "$delivered" -ge "$spawn_epoch" ] && [ $((now - resolved)) -le "$PERSIST_REUSE" ] || continue
    [ "$resolved" -gt "$best_at" ] || continue
    best=$rec
    best_at=$resolved
  done
  [ -n "$best" ] || return 0
  corr=$(fm_pending_reply_get "$best" corr_id)
  # Inbox messages are numbered in delivery order, so any message numbered
  # after the request's own reached the mate after it answered.
  seq=$(grep -lF "corr=$corr" "$STATE/$ID.inbox"/*.msg "$STATE/$ID.inbox"/handled/*.msg 2>/dev/null | tail -1)
  seq=$(basename "${seq:-x}" .msg)
  case "$seq" in ''|*[!0-9]*) return 0 ;; esac
  for msg in "$STATE/$ID.inbox"/*.msg "$STATE/$ID.inbox"/handled/*.msg; do
    [ -f "$msg" ] || continue
    n=$(basename "$msg" .msg)
    case "$n" in ''|*[!0-9]*) return 0 ;; esac
    [ $((10#$n)) -le $((10#$seq)) ] || return 0
  done
  printf '%s' "$corr"
}

# Wait, within the remaining persist budget, until the mate has finished the
# turn in which it answered: its answer lands on the parent channel before its
# reply finishes, and stopping it mid-reply interrupts that reply and leaves its
# composer unreadable, so the stop would refuse. Returns non-zero with
# PERSIST_REASON set.
settle_turn() {  # <deadline>
  local deadline=$1 obs fallback=0
  while :; do
    obs=$(fm_pending_reply_backend_observation "$ENDPOINT_BACKEND" "$ENDPOINT_TARGET" \
      "fm-$ID" "$(fm_meta_get "$META" harness)")
    case "$obs" in
      idle) return 0 ;;
      fallback-idle)
        # A rendered idle alone is weak; two in a row is a settled screen.
        fallback=$((fallback + 1))
        [ "$fallback" -lt 2 ] || return 0
        ;;
      *) fallback=0 ;;
    esac
    if [ "$(date +%s)" -ge "$deadline" ]; then
      PERSIST_REASON="it wrote down its open work but was still finishing its reply when the wait ran out; retry once it is idle, and that answer will be reused rather than asked for again"
      return 1
    fi
    sleep "$PERSIST_POLL"
  done
}

# Ask a running mate to write down what it holds only in its conversation, and
# wait for its own correlated answer. Returns non-zero with PERSIST_REASON set.
PERSIST_REASON=
PERSIST_REUSED=
persist_open_work() {
  local corr send_out deadline
  deadline=$(($(date +%s) + PERSIST_WAIT))
  PERSIST_REUSED=$(reusable_persist_answer)
  if [ -n "$PERSIST_REUSED" ]; then
    settle_turn "$deadline"
    return
  fi
  if ! corr=$(fm_pending_reply_create "$FM_HOME" "$STATE" "$ID" "$SLEEP_PERSIST_REQUEST"); then
    PERSIST_REASON="its answer about its open work cannot be tracked, so a clean sleep could not be proven"
    return 1
  fi
  if ! send_out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    FM_PENDING_REPLY_EXISTING_CORR="$corr" \
    "$SCRIPT_DIR/fm-send.sh" "$ID" "$SLEEP_PERSIST_REQUEST" 2>&1); then
    fm_pending_reply_discard_undelivered "$STATE" "$corr" >/dev/null 2>&1 || true
    PERSIST_REASON="the request to write down its open work could not be delivered: $(reported_reason "$send_out")"
    return 1
  fi
  while :; do
    fm_pending_reply_try_resolve "$STATE" "$corr" && { settle_turn "$deadline"; return; }
    if [ "$(date +%s)" -ge "$deadline" ]; then
      # The final recheck lets an answer that landed during the last wait win.
      fm_pending_reply_try_resolve "$STATE" "$corr" && { settle_turn "$deadline"; return; }
      PERSIST_REASON="it did not confirm within ${PERSIST_WAIT}s that its open work is written down; its answer may still arrive, so retry once it has"
      return 1
    fi
    sleep "$PERSIST_POLL"
  done
}

# Publish <source> over the task record, atomically and under its meta lock.
publish_record() {  # <source>
  fm_backlog_atomic_transition publish "$1" "$META" "task record" "$STATE"
}

cmd_sleep() {
  local home child spawn_gen stop_out since close_ok=1
  require_secondmate_record
  if fm_secondmate_asleep "$META"; then
    echo "asleep: $ID has been asleep since $(fm_secondmate_asleep_since_utc "$META"); nothing changed. Wake it with: $WAKE_CMD"
    return 0
  fi
  take_liveness_lock

  home=$(fm_meta_get "$META" home)
  if [ -n "$home" ] && [ -d "$home/state" ]; then
    for child in "$home/state"/*.meta; do
      [ -e "$child" ] || [ -L "$child" ] || continue
      die "second mate $ID still has work under way in its home ($(basename "$child")); let it finish before putting the mate to sleep. Nothing was changed"
    done
  fi
  if fm_pending_reply_task_has_open "$STATE" "$ID"; then
    die "second mate $ID still owes a reply to an open request from this home; let it answer before putting it to sleep. Nothing was changed"
  fi
  if [ -e "$STATE/.backlog-handoff-$ID.wake-pending" ] || [ -L "$STATE/.backlog-handoff-$ID.wake-pending" ]; then
    die "second mate $ID has handed-off work it has not yet been told about; it has work, so it was not put to sleep. Nothing was changed"
  fi

  spawn_gen=$(fm_meta_get "$META" spawn_gen)
  read_endpoint
  case "$ENDPOINT_STATE" in
    alive)
      fm_secondmate_restart_capable "$META" \
        || die "second mate $ID cannot be put to sleep: $FM_SECONDMATE_RESTART_REASON. Nothing was changed"
      persist_open_work \
        || die "second mate $ID was not put to sleep: $PERSIST_REASON. Its agent was left running and nothing else changed"
      if ! stop_out=$(FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
        "$SCRIPT_DIR/fm-control.sh" "$ID" exit 2>&1); then
        die "second mate $ID was not put to sleep: its agent could not be stopped: $(reported_reason "$stop_out"). Nothing else was changed"
      fi
      ;;
    dead|missing) ;;
    *)
      die "second mate $ID was not put to sleep: its endpoint $ENDPOINT_TARGET reads $ENDPOINT_STATE (backend $ENDPOINT_BACKEND), so whether its agent is running cannot be told. Nothing was changed"
      ;;
  esac

  # From here the agent is stopped. Hold the mate's lifecycle and record locks
  # for the close and the mark, and prove the record is still the one sampled.
  fm_lock_acquire_wait_bounded "$CONTROL_LOCK" 30 \
    || die "second mate $ID's agent is stopped, but another lifecycle action took over before it could be marked asleep, so it is not asleep and ordinary recovery will relaunch it"
  CONTROL_LOCK_HELD=1
  META_LOCK=$(fm_meta_lock_path "$META") || die "the record lock for second mate $ID cannot be resolved; its agent is stopped but it is not marked asleep"
  fm_lock_acquire_wait "$META_LOCK" || die "the record lock for second mate $ID cannot be taken; its agent is stopped but it is not marked asleep"
  META_LOCK_HELD=1
  [ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_meta_get "$META" spawn_gen)" = "$spawn_gen" ] \
    || die "second mate $ID's record changed while it was being put to sleep; it was not marked asleep, so reconcile its current record"
  read_endpoint
  [ "$ENDPOINT_STATE" != alive ] \
    || die "second mate $ID's agent is running again on $ENDPOINT_TARGET; it was not marked asleep"
  close_endpoint || close_ok=0

  SCRATCH="$STATE/.$ID.meta.asleep.${BASHPID:-$$}"
  since=$(date +%s)
  { grep -v '^asleep=' "$META"; printf 'asleep=%s\n' "$since"; } > "$SCRATCH" \
    || die "second mate $ID's agent is stopped, but its asleep record could not be prepared, so ordinary recovery may relaunch it"
  publish_record "$SCRATCH" \
    || die "second mate $ID's agent is stopped, but its asleep record could not be published ($FM_BACKLOG_TRANSITION_ERROR), so ordinary recovery may relaunch it"
  SCRATCH=

  if [ "$close_ok" -eq 0 ]; then
    echo "asleep: $ID since $(fm_secondmate_asleep_since_utc "$META"); its agent is stopped and its home, records, backlog, and route are kept, but its $ENDPOINT_BACKEND endpoint $ENDPOINT_TARGET still reads $ENDPOINT_STATE and could not be confirmed closed - close it by hand. Wake it with: $WAKE_CMD"
    return 4
  fi
  echo "asleep: $ID since $(fm_secondmate_asleep_since_utc "$META"); its agent is stopped and its endpoint closed, and its home, records, backlog, and route are kept. Wake it with: $WAKE_CMD"
  return 0
}

cmd_wake() {
  local backup spawn_out spawn_rc=0 spawned
  require_secondmate_record
  if ! fm_secondmate_asleep "$META"; then
    echo "awake: $ID is not asleep; nothing changed"
    return 0
  fi
  take_liveness_lock
  # Re-read under the lock: a concurrent wake may have finished first.
  if ! fm_secondmate_asleep "$META"; then
    echo "awake: $ID is not asleep; nothing changed"
    return 0
  fi

  read_endpoint
  case "$ENDPOINT_STATE" in
    missing) ;;
    dead)
      # A shell left behind on the recorded endpoint occupies its name; close
      # it first, as liveness recovery does before every relaunch.
      close_endpoint \
        || die "second mate $ID stays asleep: what remains of its endpoint $ENDPOINT_TARGET reads $ENDPOINT_STATE and could not be closed before the launch"
      ;;
    alive)
      die "second mate $ID stays asleep: its recorded endpoint $ENDPOINT_TARGET shows a running agent although the mate is recorded asleep; inspect that endpoint before waking it"
      ;;
    *)
      die "second mate $ID stays asleep: its endpoint $ENDPOINT_TARGET reads $ENDPOINT_STATE (backend $ENDPOINT_BACKEND), so a launch could duplicate a running agent"
      ;;
  esac

  # Kept so a launch that fails after removing the record cannot lose the mate.
  backup="$STATE/.$ID.meta.wake-backup.${BASHPID:-$$}"
  cp -p "$META" "$backup" || die "second mate $ID stays asleep: its record could not be copied aside before the launch"
  SCRATCH=$backup

  spawn_out=$(FM_HOME="$FM_HOME" FM_SECONDMATE_WAKE="$ID" \
    "$SCRIPT_DIR/fm-spawn.sh" "$ID" --secondmate 2>&1) || spawn_rc=$?
  if [ "$spawn_rc" -eq 0 ] && [ -f "$META" ] && ! fm_secondmate_asleep "$META"; then
    spawned=$(printf '%s\n' "$spawn_out" | grep '^spawned ' | tail -1)
    echo "awake: $ID relaunched in its own home${spawned:+ ($spawned)}; it reconciles its own records at startup"
    return 0
  fi

  if [ ! -e "$META" ] && [ ! -L "$META" ]; then
    META_LOCK=$(fm_meta_lock_path "$META") && fm_lock_acquire_wait "$META_LOCK" && META_LOCK_HELD=1
    if [ "$META_LOCK_HELD" = 1 ] && [ ! -e "$META" ] && [ ! -L "$META" ] && publish_record "$backup"; then
      SCRATCH=
      die "second mate $ID stays asleep: its launch failed ($(reported_reason "$spawn_out")), and its asleep record was restored"
    fi
    SCRATCH=
    die "second mate $ID's launch failed ($(reported_reason "$spawn_out")) and its record could not be restored; its record copy is kept at $backup"
  fi
  if fm_secondmate_asleep "$META"; then
    die "second mate $ID stays asleep: its launch failed: $(reported_reason "$spawn_out")"
  fi
  die "second mate $ID's launch reported failure after it republished the mate's record ($(reported_reason "$spawn_out")); it is no longer marked asleep, so reconcile its current record"
}

case "$VERB" in
  sleep) cmd_sleep ;;
  wake) cmd_wake ;;
esac
