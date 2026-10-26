#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

# A GitHub-hosted job has its own disposable VM. Never run this on a developer's Mac
# or a self-hosted runner with someone else's desktop and clipboard.
if [[ "${GITHUB_ACTIONS:-}" != true || "${RUNNER_ENVIRONMENT:-}" != github-hosted ||
      "${RUNNER_OS:-}" != macOS || -z "${RUNNER_TEMP:-}" ]]; then
    print -u2 "This command requires a dedicated GitHub-hosted macOS runner. Use scripts/test-tart.sh locally."
    exit 2
fi

mkdir -p .build/ci-logs
JOTLET_DATA_DIR="${RUNNER_TEMP}/jotlet-native-ci" \
    ./dist/Jotlet.app/Contents/MacOS/Jotlet --smoke-test 2>&1 | tee .build/ci-logs/native.log
python3 - <<'PY'
from pathlib import Path
log = Path('.build/ci-logs/native.log').read_text()
checks = sum(line.startswith('PASS ') for line in log.splitlines())
if 'Native integration checks completed.' not in log or checks < 100:
    raise SystemExit(f'Incomplete native checks: {checks} passed; expected at least 100.')
print(f'Native editor integration: {checks} checks passed.')
PY
