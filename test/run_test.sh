#!/bin/bash
# Test of the dpq queue with small copies of the half-car personal case.
#
#   bash run_test.sh [np]
#
# Settings come from test.conf, next to this script (see test.conf.example).
# Everything runs inside ~/dpq_test: a private copy of dpq, the geometry and
# the test cases. The real run/ folder and the installed dpq are not touched.
# The report is written next to this script, in reports/<date>_<time>/.

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DPQ_SRC="$(dirname "$KIT_DIR")"

# ============================ SETTINGS ==================================
# test.conf, next to this script, sets TEMPLATE and GEOMETRY and can override
# the others.
FOAM_BASHRC="/usr/lib/openfoam/openfoam2512/etc/bashrc"
TEMPLATE=""                 # half-car personal case to copy the structure from
GEOMETRY=""                 # folder with the .obj files for triSurface_0deg
WORK="$HOME/dpq_test"
NTFY_TOPIC=""
ITERATIONS=30
COARSEN=3
WAIT_LIMIT=3600             # seconds allowed to each phase of the test
# ========================================================================

[ -f "$KIT_DIR/test.conf" ] && source <(tr -d '\r' < "$KIT_DIR/test.conf")

STAMP="$(date +%Y%m%d_%H%M%S)"
RUN="$WORK/run_$STAMP"
STATE="$RUN/state"
DPQ="$WORK/dpq/dpq"
REPORT_DIR="$KIT_DIR/reports/$STAMP"
REPORT="$REPORT_DIR/report.txt"

PASSED=0
FAILED=0
CHECKS=()
T_START="$(date +%s)"
COMPLETED=0

say()  { echo "[$(date '+%H:%M:%S')] $*"; }
stop() { echo "run_test: $*" >&2; exit 1; }

is_wsl() { grep -qi microsoft /proc/version 2> /dev/null; }

physical_cores() {
    local n
    n="$(lscpu -p=Core,Socket 2> /dev/null | grep -v '^#' | sort -u | wc -l)"
    [ "${n:-0}" -gt 0 ] 2> /dev/null || n="$(nproc --all)"
    echo "$n"
}

check() {
    # check <description> <command...>: the command decides pass or fail
    local what="$1"
    shift
    if "$@" > /dev/null 2>&1; then
        PASSED=$((PASSED + 1)); CHECKS+=("PASS  $what")
        say "  PASS  $what"
    else
        FAILED=$((FAILED + 1)); CHECKS+=("FAIL  $what")
        say "  FAIL  $what"
    fi
}

current_case() { [ -f "$STATE/current.case" ] && basename "$(cut -f1 "$STATE/current.case")"; }
current_step() { [ -f "$STATE/current.step" ] && cut -f1 "$STATE/current.step"; }
worker_alive() { "$DPQ" status | grep -q "^Worker: running"; }
worker_done()  { ! worker_alive; }
running()      { [ "$(current_case)" = "$1" ]; }

# History of the last run of a case: hist <case> <field>
# fields: 2 status, 6 step, 7 reason
hist() { awk -F'\t' -v c="$RUN/$1" -v f="$2" '$3 == c {v = $f} END {print v}' "$STATE/history.tsv"; }

queued() { cut -f1 "$STATE/queue.tsv" 2> /dev/null | grep -Fxq "$RUN/$1"; }

past_first_steps() {
    # true once the case is at snappyHexMesh or later
    running "$1" || return 1
    case "$(current_step)" in
        ""|preProcess|surfaceFeatureExtract|blockMesh|"decomposePar (block mesh)"|"checkMesh (block mesh)") return 1 ;;
    esac
    return 0
}

# Processes still working inside a case folder
leftovers() {
    local p
    for p in /proc/[0-9]*; do
        [ "$(readlink "$p/cwd" 2> /dev/null)" = "$RUN/$1" ] && echo "${p#/proc/}"
    done
}
no_leftovers() { [ -z "$(leftovers "$1")" ]; }

# The runs must leave both the original geometry and its copy as they were
geometry_untouched() {
    local f
    for f in "$GEOMETRY"/*.obj; do
        cmp -s "$f" "$WORK/geometry/$(basename "$f")" || return 1
    done
}

# wait_for <description> <command...>: polls until the command is true
wait_for() {
    local what="$1" t=0
    shift
    say "waiting: $what"
    until "$@"; do
        sleep 5
        t=$((t + 5))
        if [ "$t" -ge "$WAIT_LIMIT" ]; then
            say "TIMEOUT after ${WAIT_LIMIT}s: $what"
            return 1
        fi
        if ! worker_alive && [ "$1" != "worker_done" ]; then
            say "the queue stopped before: $what"
            return 1
        fi
        [ $((t % 60)) -eq 0 ] && say "  ... $(current_case): $(current_step)"
    done
    return 0
}

write_report() {
    local c f
    mkdir -p "$REPORT_DIR"
    {
        echo "dpq test report - $STAMP"
        [ "$COMPLETED" = "1" ] || echo "*** INCOMPLETE: the test did not reach the end ***"
        echo
        echo "== RESULT: $PASSED passed, $FAILED failed, $(( ($(date +%s) - T_START) / 60 )) minutes"
        printf '%s\n' "${CHECKS[@]}"
        echo
        echo "== ENVIRONMENT"
        echo "system:    $(uname -sr) $(is_wsl && echo '(WSL)')"
        echo "distro:    $(. /etc/os-release 2> /dev/null; echo "$PRETTY_NAME")"
        echo "OpenFOAM:  ${WM_PROJECT_VERSION:-?}  ($FOAM_BASHRC)"
        echo "mpirun:    $(mpirun --version 2> /dev/null | head -n 1)"
        echo "python:    $(python3 --version 2>&1), numpy $(python3 -c 'import numpy; print(numpy.__version__)' 2>&1)"
        echo "cores:     $(physical_cores) physical, $(nproc) logical; np used: $NP"
        echo "memory:    $(free -g | awk 'NR==2 {print $2 " GB"}')"
        echo "work dir:  $RUN  ($(df -Ph "$WORK" 2> /dev/null | awk 'NR==2 {print $4}') free)"
        echo "template:  $TEMPLATE"
        echo "geometry:  $GEOMETRY"
        echo "dpq:       $(grep -m1 '^DPQ_VERSION' "$DPQ" 2> /dev/null)"
        echo
        echo "== HISTORY"
        "$DPQ" history 30 2>&1
        echo
        echo "== QUEUE AT THE END"
        "$DPQ" status 2>&1
        echo
        echo "== TEST NOTIFICATION"
        cat "$RUN/test_notify.txt" 2> /dev/null
        echo
        echo "== MESH OF t1_ok"
        grep -E "^ +cells:|Mesh OK|Failed [0-9]+ mesh checks" "$RUN/t1_ok/log_mesh/06_checkMesh" 2> /dev/null
        grep -E "Finished meshing" "$RUN/t1_ok/log_mesh/05_snappyHexMesh" 2> /dev/null
        echo
        echo "== QUEUE LOG"
        cat "$STATE/worker.log" 2> /dev/null
        echo
        echo "== SCRIPT OUTPUT"
        cat "$RUN/run_test.out" 2> /dev/null
    } > "$REPORT" 2>&1

    cp "$STATE/history.tsv" "$REPORT_DIR/" 2> /dev/null
    for c in "$RUN"/t[0-9]*; do
        [ -d "$c" ] || continue
        {
            for f in "$c"/log_mesh/* "$c"/log_solve/*; do
                [ -f "$f" ] || continue
                echo "=================== ${f#"$c"/}  ($(wc -l < "$f") lines)"
                tail -n 25 "$f" | cut -c1-240
            done
        } > "$REPORT_DIR/logs_$(basename "$c").txt" 2> /dev/null
    done
    echo
    echo "Report: $REPORT_DIR"
}

# ============================ PRE-FLIGHT ================================

[ -f "$KIT_DIR/test.conf" ] || stop "test.conf not found: copy test.conf.example to test.conf and fill it in"
[ -n "$TEMPLATE" ] && [ -n "$GEOMETRY" ] || stop "set TEMPLATE and GEOMETRY in test.conf"
[ -f "$FOAM_BASHRC" ] || stop "OpenFOAM not found: $FOAM_BASHRC (set FOAM_BASHRC in test.conf)"
[ -f "$DPQ_SRC/dpq" ] || stop "dpq not found in $DPQ_SRC"
[ -f "$TEMPLATE/initialConditions" ] || stop "template case not found: $TEMPLATE"
[ -n "$(ls "$GEOMETRY"/*.obj 2> /dev/null)" ] || stop "no .obj files in $GEOMETRY"
python3 -c "import numpy" 2> /dev/null || stop "python3 with numpy is needed (sudo apt install python3-numpy)"
for tool in flock setsid pgrep lscpu curl awk; do
    command -v "$tool" > /dev/null || stop "command not found: $tool"
done

if [ "$(id -u)" = "0" ] && [ -z "$OMPI_ALLOW_RUN_AS_ROOT" ]; then
    stop "you are root: Open MPI refuses to run as root. Run the test as a normal user."
fi

NP="${1:-}"
if [ -z "$NP" ]; then
    NP="$(physical_cores)"
    [ "$NP" -gt 8 ] && NP=8
fi
[[ "$NP" =~ ^[0-9]+$ ]] && [ "$NP" -ge 1 ] || stop "np must be a number: $NP"

mkdir -p "$WORK/dpq" "$WORK/geometry" "$RUN" || stop "cannot create $WORK"
FREE_GB="$(df -Pk "$WORK" | awk 'NR==2 {print int($4 / 1048576)}')"
[ "$FREE_GB" -ge 15 ] || stop "only $FREE_GB GB free in $WORK, 15 needed"
if [ -x "$DPQ" ] && "$DPQ" status 2> /dev/null | grep -q "^Worker: running"; then
    stop "a previous test is still running: stop it with '$DPQ abort'"
fi

exec > >(tee -i "$RUN/run_test.out") 2>&1
trap write_report EXIT
trap 'say "interrupted: stopping the queue"; "$DPQ" abort > /dev/null 2>&1; exit 130' INT TERM

say "dpq test, np = $NP, work folder $RUN"

# Private copy of dpq, with its own configuration and state
tr -d '\r' < "$DPQ_SRC/dpq" > "$DPQ" && chmod +x "$DPQ"
{
    echo "FOAM_BASHRC=\"$FOAM_BASHRC\""
    echo "RUN_DIR=\"$RUN\""
    echo "STATE_DIR=\"$STATE\""
    echo "MACHINE_NAME=\"$(hostname)-test\""
    echo "MIN_FREE_GB=5"
    echo "NOTIFY_DESKTOP=$(is_wsl && echo 0 || echo 1)"
    echo "NTFY_TOPIC=\"$NTFY_TOPIC\""
} > "$WORK/dpq/dpq.conf"

say "copying the geometry into $WORK/geometry (only the first time)"
for f in "$GEOMETRY"/*.obj; do
    dest="$WORK/geometry/$(basename "$f")"
    if [ ! -f "$dest" ] || [ "$(stat -c %s "$f")" != "$(stat -c %s "$dest")" ]; then
        cp "$f" "$dest" || stop "copy failed: $f"
    fi
done

say "creating the test cases"
make_case() {
    python3 "$KIT_DIR/make_test_case.py" "$TEMPLATE" "$WORK/geometry" "$RUN/$1" \
        --np "$NP" --iterations "$ITERATIONS" --coarsen "$COARSEN" "${@:2}" || stop "cannot create $1"
}
make_case t1_ok
make_case t2_snappy_broken --break snappy
make_case t3_solver_broken --break solver
make_case t4_np_too_high   --break np
make_case t5_to_skip
make_case t6_added_late
make_case t7_left_in_queue

load_openfoam() { source "$FOAM_BASHRC"; }
load_openfoam

# ============================ SCENARIO ==================================

say "test notification"
"$DPQ" test-notify > "$RUN/test_notify.txt" 2>&1
cat "$RUN/test_notify.txt"
check "test notification sent without errors" bash -c "! grep -q 'notification failed' '$RUN/test_notify.txt'"

say "queueing five cases and starting the queue"
"$DPQ" add -o tester t1_ok t2_snappy_broken t3_solver_broken t4_np_too_high t5_to_skip
"$DPQ" start || stop "the queue did not start"

scenario() {
    wait_for "t1_ok running" running t1_ok || return 1
    "$DPQ" add -o late t6_added_late t7_left_in_queue
    check "cases can be added while the queue runs" queued t7_left_in_queue
    check "a case already running is refused by 'add'" bash -c "! '$DPQ' add t1_ok"
    "$DPQ" status

    wait_for "t5_to_skip at snappyHexMesh, to skip it" past_first_steps t5_to_skip || return 1
    say "skipping t5_to_skip during: $(current_step)"
    "$DPQ" skip
    sleep 15
    check "no process left in the skipped case" no_leftovers t5_to_skip

    wait_for "t6_added_late running, to ask for a stop" running t6_added_late || return 1
    "$DPQ" stop

    wait_for "the queue to stop after t6_added_late" worker_done || return 1
    return 0
}

if scenario; then
    COMPLETED=1
else
    say "scenario interrupted: stopping the queue"
    "$DPQ" abort > /dev/null 2>&1
    sleep 10
fi

# ============================= CHECKS ===================================

say "checks"
check "t1_ok finished OK"                       [ "$(hist t1_ok 2)" = "OK" ]
check "t1_ok left time folder $ITERATIONS with U" [ -e "$RUN/t1_ok/$ITERATIONS/U" ]
check "t1_ok left postProcessing"               [ -n "$(ls -A "$RUN/t1_ok/postProcessing" 2> /dev/null)" ]
check "t2 failed at snappyHexMesh"              [ "$(hist t2_snappy_broken 2)/$(hist t2_snappy_broken 6)" = "FAILED/snappyHexMesh" ]
check "t2 reason is a FOAM FATAL ERROR"         grep -q "FOAM FATAL" <<< "$(hist t2_snappy_broken 7)"
check "t3 failed at simpleFoam"                 [ "$(hist t3_solver_broken 2)/$(hist t3_solver_broken 6)" = "FAILED/simpleFoam" ]
check "t3 reason is a FOAM FATAL ERROR"         grep -q "FOAM FATAL" <<< "$(hist t3_solver_broken 7)"
check "t4 failed at the pre-check on np"        [ "$(hist t4_np_too_high 2)/$(hist t4_np_too_high 6)" = "FAILED/pre-check" ]
check "t5 recorded as SKIPPED"                  [ "$(hist t5_to_skip 2)" = "SKIPPED" ]
check "t6 (added while running) finished OK"    [ "$(hist t6_added_late 2)" = "OK" ]
check "t7 still queued after 'stop'"            queued t7_left_in_queue
check "t7 never started"                        [ -z "$(hist t7_left_in_queue 2)" ]
"$DPQ" remove t7_left_in_queue
check "'remove' empties the queue"              [ ! -s "$STATE/queue.tsv" ]
check "queue worker not running at the end"     worker_done
check "no notification failed during the run"   bash -c "! grep -q 'notification failed' '$STATE/worker.log'"
check "geometry files not modified by the runs" geometry_untouched

echo
say "RESULT: $PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ] && [ "$COMPLETED" = "1" ]
