#!/usr/bin/env bash
# export-push.sh — scan + delta-export + push to the VPS inbox. LMF (or any
# POSIX box). Fired by the Claude Code SessionEnd hook; safe to run by hand.
# Same spool-then-push failure model as export-push.ps1: nothing is deleted
# until scp succeeds, so failed pushes retry on the next session.
set -euo pipefail

export TOKEN_DASHBOARD_BOX="${TOKEN_DASHBOARD_BOX:-LMF}"

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# SCRATCH is LOCAL to the sending box (spool, stamp, log) — it follows this box's own
# SCRATCH_DIR and the fallback stays wherever this box keeps scratch.
SCRATCH="${SCRATCH_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)/_scratch}"
SPOOL="$SCRATCH/token-dashboard-spool"
STAMP="$SCRATCH/token-dashboard-lastpush"
LOG="$SCRATCH/token-dashboard-push.log"
# INBOX is a path on the RECEIVING box and must match the VPS's TOKEN_DASHBOARD_INBOX,
# which moved to gatorbyte-os/run on 2026-08-24 (QUEUE 2026-08-23-1830). The old location
# is a symlink to the new one for exactly this reason — a sender that has not pulled yet
# still lands in the swept directory instead of dropping exports somewhere nobody reads.
# That symlink dies with Projects/_scratch at the cutover; this line is what has to be
# live on every sending box before then.
INBOX="vps:~/Claude/gatorbyte-os/run/token-dashboard-inbox/"

mkdir -p "$SPOOL"

# debounce: skip if we pushed in the last 15 minutes
if [ -f "$STAMP" ] && [ -n "$(find "$STAMP" -mmin -15 2>/dev/null)" ]; then
    exit 0
fi

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

OUT="$SPOOL/td-${TOKEN_DASHBOARD_BOX}-$(date '+%Y%m%d-%H%M%S').json.gz"
cd "$REPO"
python3 cli.py export --out "$OUT" > /dev/null

pushed=0
for f in "$SPOOL"/*.json.gz; do
    [ -e "$f" ] || continue
    if scp -q "$f" "$INBOX"; then
        rm -f "$f"
        pushed=$((pushed + 1))
    else
        log "ERROR: scp failed for $f"
        exit 1
    fi
done
touch "$STAMP"
log "pushed $pushed file(s)"
