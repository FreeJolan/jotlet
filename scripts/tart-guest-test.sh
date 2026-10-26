#!/bin/zsh
set -euo pipefail

task_input="/Volumes/My Shared Files/input"
task_output="/Volumes/My Shared Files/output"
# Fail closed if this script is accidentally executed on the host.
if [[ ! "$0" -ef "$task_input/guest-test.sh" || ! -d "$task_output" ]]; then
    print -u2 "This script must run inside the Tart VM through scripts/test-tart.sh."
    exit 2
fi

task_root="$(mktemp -d /tmp/jotlet-tart.XXXXXX)"
task_preview_pid=""
function task_cleanup() {
    if [[ -n "$task_preview_pid" ]]; then
        kill -TERM "$task_preview_pid" 2>/dev/null || true
        wait "$task_preview_pid" 2>/dev/null || true
    fi
    rm -rf "$task_root"
}
trap task_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

sw_vers > "$task_output/guest-system.txt"
uname -m >> "$task_output/guest-system.txt"
id >> "$task_output/guest-system.txt"
ditto "$task_input/Jotlet.app" "$task_root/Jotlet.app"
task_executable="$task_root/Jotlet.app/Contents/MacOS/Jotlet"
codesign --verify --deep --strict "$task_root/Jotlet.app"

# All AppKit windows and pasteboard operations belong to the guest desktop.
"$task_executable" --smoke-test | tee "$task_output/smoke.log"
JOTLET_VM_TEST=1 JOTLET_DATA_DIR="$task_root/window-data" \
    "$task_executable" --window-checks | tee "$task_output/windows.log"

for task_variant in light-active light-inactive dark-active dark-inactive; do
    task_args=(--library-preview)
    [[ "$task_variant" == dark-* ]] && task_args+=(--dark)
    [[ "$task_variant" == *-inactive ]] && task_args+=(--inactive)
    JOTLET_DATA_DIR="$task_root/data" "$task_executable" "${task_args[@]}" \
        > "$task_output/$task_variant.log" 2>&1 &
    task_preview_pid=$!
    sleep 3
    kill -0 "$task_preview_pid"
    screencapture -x "$task_output/$task_variant.png"
    kill -TERM "$task_preview_pid"
    wait "$task_preview_pid" 2>/dev/null || true
    task_preview_pid=""
done
for task_variant in light dark; do
    task_args=(--ui-fixture)
    [[ "$task_variant" == dark ]] && task_args+=(--dark)
    JOTLET_DATA_DIR="$task_root/editor-$task_variant" "$task_executable" "${task_args[@]}" \
        > "$task_output/editor-$task_variant.log" 2>&1 &
    task_preview_pid=$!
    sleep 3
    kill -0 "$task_preview_pid"
    screencapture -x "$task_output/editor-$task_variant.png"
    kill -TERM "$task_preview_pid"
    wait "$task_preview_pid" 2>/dev/null || true
    task_preview_pid=""
done
print "Native checks completed; library and editor screenshots saved for visual review."
