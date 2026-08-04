#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
DB="${1:-$SCRIPT_DIR/bench.db}"

if [[ ! -f "$DB" ]]; then
    echo "Database not found: $DB"
    echo "Run: python3 bench/generate_db.py"
    exit 1
fi
DB="$(cd "$(dirname "$DB")" && pwd)/$(basename "$DB")"

# Build first.
make -C "$PROJECT_DIR" histdb.lua >/dev/null 2>&1

export HISTDB_PATH="$DB"
export HISTDB_SESSION_ID="not-a-real-session"
HISTDB="$PROJECT_DIR/histdb"

echo "Database: $DB ($(sqlite3 "$DB" 'select count(*) from history') rows)"
echo "Commit:   $(git -C "$PROJECT_DIR" log --oneline -1)"
echo

run_query() {
    local label="$1"
    local sql="$2"
    local timeout="${3:-120}"

    echo "--- $label ---"
    echo "  $sql"
    # Use timeout to prevent runaway queries.
    local start end_t elapsed
    start=$(date +%s%N)
    timeout "$timeout" "$HISTDB" "$sql" >/dev/null 2>&1 && rc=0 || rc=$?
    end_t=$(date +%s%N)
    elapsed=$(( (end_t - start) / 1000000 ))

    if [[ $rc -eq 124 ]]; then
        echo "  TIMEOUT after ${timeout}s"
    elif [[ $rc -ne 0 ]]; then
        echo "  ERROR (exit code $rc)"
    else
        echo "  ${elapsed}ms"
    fi
    echo
}

run_query "self-join (no ORDER BY)" \
    "select linked.session_id, linked.timestamp, linked.entry from h as token_load inner join h as linked on linked.session_id = token_load.session_id where token_load.entry match 'RARE_BENCH_TOKEN obscure benchmark'"

run_query "self-join (with ORDER BY)" \
    "select linked.session_id, linked.timestamp, linked.entry from h as token_load inner join h as linked on linked.session_id = token_load.session_id where token_load.entry match 'RARE_BENCH_TOKEN obscure benchmark' order by linked.session_id, linked.timestamp"

run_query "simple MATCH" \
    "select timestamp, entry from h where entry match 'git status'"

run_query "simple equality" \
    "select timestamp, entry from h where hostname = 'workstation'"

run_query "LIMIT 10 (ordered)" \
    "select timestamp, entry from h order by timestamp desc limit 10"
