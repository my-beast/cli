#!/usr/bin/env bash
# Every command's tests, one after the other: `/bin/bash test.sh` (3.2 on macOS, the oldest bash they must work with).

set -u

cd "$(dirname "$0")" || exit 1
status=0
for tool in deploy secrets vulnerabilities; do
    printf '%s: ' "$tool"
    /bin/bash "$tool/tests/run.sh" || status=1
done
exit $status
