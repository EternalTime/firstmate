# shellcheck shell=bash
# fm-secondmate-sleep-lib.sh - the asleep record of a persistent second mate.
# Source only; defines functions and one result variable, and does nothing else.
#
# A sleeping second mate has had its agent stopped and its endpoint closed, and
# keeps everything else: this home's task record state/<id>.meta, its own home
# with every record and its backlog, its lease, and its data/secondmates.md
# route. It costs nothing, and nothing restarts it until it is woken.
# bin/fm-secondmate-sleep.sh owns the sleep and wake transitions and is the only
# writer of the mark this library reads.
#
# The mark is one `asleep=<epoch>` line in the task record itself, so it shares
# the record's lifetime instead of needing a second file kept in step with it:
# retiring an asleep mate with bin/fm-teardown.sh removes the mark with the
# record, and the wake relaunch republishes the record without it. A record
# that carries the mark is asleep whatever its epoch reads, so a damaged value
# still keeps every automatic path away from the mate.
#
# Every automatic path that would otherwise restart, nudge, message, or raise an
# alert about a mate tests fm_secondmate_asleep on its record and steps aside:
# the liveness probe (bin/fm-secondmate-liveness-lib.sh) that both the
# session-start sweep and the watcher drive, the live second-mate enumeration
# (bin/fm-ff-lib.sh) behind session-start convergence, inherited-material push,
# and /updatefirstmate's restart set, the watcher's endpoint and wake-loop scans,
# bin/fm-send.sh and bin/fm-backlog-handoff.sh, which refuse with
# fm_secondmate_asleep_refusal, and bin/fm-spawn.sh, which refuses to launch an
# asleep mate except for the wake transition itself.

# Read <meta-file> once, in pure bash because the watcher asks on every poll:
# FM_SECONDMATE_ASLEEP_SINCE is the recorded epoch when the file is a regular
# second-mate task record carrying the mark (its last kind= line decides, as
# fm_meta_get reads it), and empty otherwise.
FM_SECONDMATE_ASLEEP_SINCE=
_fm_secondmate_asleep_read() {  # <meta-file>
  local meta=$1 line kind='' marked=0 since=''
  FM_SECONDMATE_ASLEEP_SINCE=
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      kind=*) kind=${line#kind=} ;;
      asleep=*) marked=1; since=${line#asleep=} ;;
    esac
  done < "$meta" 2>/dev/null || return 1
  [ "$kind" = secondmate ] && [ "$marked" = 1 ] || return 1
  FM_SECONDMATE_ASLEEP_SINCE=$since
  return 0
}

# True when <meta-file> is a regular second-mate task record carrying the mark.
fm_secondmate_asleep() {  # <meta-file>
  _fm_secondmate_asleep_read "$1"
}

# The epoch the mate was put to sleep, as recorded; empty when it is not asleep.
fm_secondmate_asleep_since() {  # <meta-file>
  _fm_secondmate_asleep_read "$1" || return 0
  printf '%s' "$FM_SECONDMATE_ASLEEP_SINCE"
}

# That epoch as a UTC minute for people, or the raw value when it is not a time.
fm_secondmate_asleep_since_utc() {  # <meta-file>
  local since
  since=$(fm_secondmate_asleep_since "$1")
  case "$since" in
    ''|*[!0-9]*) printf '%s' "${since:-an unrecorded time}"; return 0 ;;
  esac
  date -u -r "$since" '+%Y-%m-%dT%H:%MZ' 2>/dev/null \
    || date -u -d "@$since" '+%Y-%m-%dT%H:%MZ' 2>/dev/null \
    || printf '%s' "$since"
}

# The one command that brings <id> back.
fm_secondmate_wake_command() {  # <id>
  printf 'bin/fm-secondmate-sleep.sh wake %s' "$1"
}

# The plain refusal every path that would reach an asleep mate prints.
fm_secondmate_asleep_refusal() {  # <id>
  printf 'second mate %s is asleep; wake it first with %s' \
    "$1" "$(fm_secondmate_wake_command "$1")"
}
