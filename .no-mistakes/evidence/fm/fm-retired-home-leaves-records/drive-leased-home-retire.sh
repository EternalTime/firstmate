#!/usr/bin/env bash
# Live drive: retire a real treehouse-leased secondmate home through bin/fm-teardown.sh.
# Usage: drive-leased-home-retire.sh <git-rev-of-firstmate> <scenario: success|failreturn>
set -u
REV=$1 SCEN=$2 WT=/Users/owlshome/.no-mistakes/worktrees/5e738cfca1e1/01M52W85XBT8H6HF22BF37B6JS
T=$(mktemp -d "${TMPDIR:-/tmp}/fm-lab.XXXXXX"); T=$(cd "$T" && pwd -P)
LAB="$T/home"; "$WT/bin/fm-lab-home.sh" create "$LAB" >/dev/null; mkdir -p "$LAB/tmux"
export TREEHOUSE_ROOT="$T/pool" TMUX_TMPDIR="$LAB/tmux" FM_HOME="$LAB"
unset TMUX NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
echo "== firstmate rev $REV, scenario $SCEN, lab $T"
git clone -q "$WT" "$T/firstmate" && git -C "$T/firstmate" -c advice.detachedHead=false checkout -q "$REV"
ROOT="$T/firstmate"
HOME_DIR=$(cd "$ROOT" && treehouse get --lease 2>/dev/null)
echo "== treehouse leased slot: $HOME_DIR"
(cd "$ROOT" && treehouse status 2>&1)
ID=sm-lab1
# Seed the slot like a real secondmate home: markers, data, state, config, a project clone, .env
printf '%s\n' "$ID" > "$HOME_DIR/.fm-secondmate-home"
printf 'schema=fm-secondmate-parent.v1\nroute=local\n' > "$HOME_DIR/.fm-secondmate-parent"
mkdir -p "$HOME_DIR"/{data,state,config,projects}
printf '# backlog\n- private item\n' > "$HOME_DIR/data/backlog.md"
printf 'prefer x\n' > "$HOME_DIR/data/preferences.md"
for i in $(seq 1 5); do mkdir -p "$HOME_DIR/data/task-$i"; echo "notes $i" > "$HOME_DIR/data/task-$i/notes.md"; done
echo 'k=v' > "$HOME_DIR/state/notes.txt"; echo 'cfg' > "$HOME_DIR/config/harness"
git clone -q "$ROOT" "$HOME_DIR/projects/alpha"
echo 'SECRET=1' > "$HOME_DIR/.env"
echo "== seeded home, ignored paths before retirement:"; git -C "$HOME_DIR" status --porcelain --ignored
tmux new-session -d -s firstmate -n "fm-$ID" "sleep 600"
printf '%s\n' "window=firstmate:fm-$ID" "endpoint_task_id=$ID" "worktree=$HOME_DIR" "project=$HOME_DIR" "harness=echo" "kind=secondmate" "mode=local-only" "home=$HOME_DIR" "spawn_gen=lab-$ID" > "$LAB/state/$ID.meta"
printf '| %s | %s |\n' "$ID" "$HOME_DIR" > /dev/null
if [ "$SCEN" = failreturn ]; then
  # Hold a foreign process inside the slot so the real treehouse return refuses.
  mkdir -p "$T/bin"; real=$(command -v treehouse)
  printf '#!/usr/bin/env bash\n[ "$1" = return ] && { echo "fatal: lab-injected return failure" >&2; exit 1; }\nexec %s "$@"\n' "$real" > "$T/bin/treehouse"; chmod +x "$T/bin/treehouse"; export PATH="$T/bin:$PATH"
fi
echo "== running: fm-teardown.sh $ID --force"
"$ROOT/bin/fm-teardown.sh" "$ID" --force; echo "== teardown exit: $?"
echo "== slot after teardown:"; ls -A "$HOME_DIR" 2>&1; echo "-- ignored/untracked left in slot:"; git -C "$HOME_DIR" status --porcelain --ignored 2>&1
echo "== treehouse status after:"; (cd "$ROOT" && PATH=${PATH#"$T/bin:"} treehouse status 2>&1)
echo "== parent archive (\$FM_HOME/data/retired-homes):"; (cd "$LAB/data" && find retired-homes -maxdepth 3 2>/dev/null | sort)
A=$(ls -d "$LAB"/data/retired-homes/*/ 2>/dev/null | head -1); [ -n "$A" ] && { echo "-- archived marker:"; cat "$A/files/.fm-secondmate-home"; echo "-- archived backlog:"; cat "$A/files/data/backlog.md"; }
echo "== task meta still present? $( [ -e "$LAB/state/$ID.meta" ] && echo yes || echo no)"
tmux kill-server 2>/dev/null; rm -rf "$T"; echo "== lab removed"
