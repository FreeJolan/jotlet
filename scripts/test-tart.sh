#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

task_vm="${JOTLET_TART_VM:-jotlet-test}"
if ! command -v tart >/dev/null; then
    print -u2 "Install Tart first: brew install cirruslabs/cli/tart"
    exit 2
fi
if ! tart get "$task_vm" --format json >/dev/null 2>&1; then
    print -u2 "Create the test VM first: tart clone ghcr.io/cirruslabs/macos-tahoe-base:latest $task_vm"
    exit 2
fi
task_running="$(tart list --source local --format json | python3 -c 'import json,sys; print(any(vm["Name"] == sys.argv[1] and vm["Running"] for vm in json.load(sys.stdin)))' "$task_vm")"
if [[ "$task_running" != False ]]; then
    print -u2 "VM $task_vm is already running. Stop it before running isolated tests."
    exit 2
fi

./scripts/build.sh
mkdir -p .build/tart-runs
task_run="$(mktemp -d "$PWD/.build/tart-runs/run.XXXXXX")"
task_input="$task_run/input"
task_output="$task_run/artifacts"
mkdir -p "$task_input" "$task_output"
ditto dist/Jotlet.app "$task_input/Jotlet.app"
cp scripts/tart-guest-test.sh "$task_input/guest-test.sh"
task_reference="$task_input/WindowReference.app/Contents"
mkdir -p "$task_reference/MacOS"
swiftc -O -target arm64-apple-macosx14.0 scripts/tart-window-reference.swift \
    -o "$task_reference/MacOS/WindowReference"
cat > "$task_reference/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>app.jotlet.tests.reference</string>
<key>CFBundleExecutable</key><string>WindowReference</string>
<key>CFBundleName</key><string>Jotlet Window Reference</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$task_input/WindowReference.app"
tart get "$task_vm" --format json > "$task_output/vm.json"

# Only these two directories are shared. No personal note data or clipboard is shared.
tart run "$task_vm" --no-graphics --no-clipboard --no-audio \
    --dir="input:${task_input}:ro" --dir="output:${task_output}" \
    > "$task_run/vm.log" 2>&1 &
task_vm_pid=$!
function task_cleanup() {
    if kill -0 "$task_vm_pid" 2>/dev/null; then
        tart stop "$task_vm" --timeout 10 > "$task_run/shutdown.log" 2>&1 || true
        wait "$task_vm_pid" 2>/dev/null || true
    fi
}
trap task_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

print "Waiting for the test VM to boot (no host windows)..."
python3 - "$task_vm" "$task_vm_pid" <<'PY'
import os, subprocess, sys, time
vm, pid = sys.argv[1], int(sys.argv[2])
deadline = time.monotonic() + 240
while time.monotonic() < deadline:
    try:
        os.kill(pid, 0)
        result = subprocess.run(["tart", "exec", vm, "/usr/bin/true"],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                timeout=5)
        if result.returncode == 0:
            break
    except ProcessLookupError:
        sys.exit("Tart stopped before the guest agent became available. See vm.log.")
    except subprocess.TimeoutExpired:
        pass
    time.sleep(2)
else:
    sys.exit("Guest agent did not become ready within four minutes. See vm.log.")
PY

tart exec "$task_vm" /bin/zsh "/Volumes/My Shared Files/input/guest-test.sh" \
    | tee "$task_output/test.log"
print "Test artifacts: $task_output"
