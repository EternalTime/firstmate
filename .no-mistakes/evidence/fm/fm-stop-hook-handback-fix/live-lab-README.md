# Live lab: overnight-stop race with a real Claude Code primary

Lab: disposable FM_HOME from bin/fm-lab-home.sh with config/supervision-host, private tmux socket fm-lab, real `claude` (v2.1.286, normal login) as the primary.
The primary ran from a plain clone of the target commit inside the lab, because the Stop auto-arm hook acts only in a plain primary checkout, not a linked worktree.
Fixture: the lab clone's bin/fm-fleet-ledger.sh was replaced by the same first-poll-pass gate the repro test uses, and a downtime marker plus an open decision were seeded.
A fresh park inside the same hook generation was started by SIGKILLing the parked host (the hook retries a host that died without a close).

Sequence, both runs: first cycle announces the episode (announced:downtime) and blocks in its first poll pass; the real Claude main runs bin/fm-wake-drain.sh and its ack (acked:handling); the gate is released; the host passes `check: rearm-resurface` through main-only; a needs-decision line is appended to demo.status.

After fix (730f674): the same Stop hook pid stayed alive, the host parked again and took over the successor arm (`take-over arm=...`), the status signal passed through, and Claude was woken ("Stop hook feedback") and drained the demo.status signal. See live-lab-host-log-after-fix.tsv and live-lab-claude-pane-after-fix.txt.

Before fix (b2b199a bin/fm-claude-stop-autoarm.sh and bin/fm-supervision-host.sh): after the pass-through the hook exited, the successor watcher was left orphaned (ppid 1), the signal landed in the wake queue, and the idle Claude main got no turn over 90 s. See live-lab-host-log-before-fix.tsv and live-lab-claude-pane-before-fix.txt.
