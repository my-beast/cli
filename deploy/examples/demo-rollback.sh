#!/usr/bin/env bash
# A stand-in rollback for trying mybeast-deploy, in the words of a typical `make rollback:staging`. Goes back to
# RELEASE when it is given (mybeast-deploy rollback --to <release> hands it over, and so does the job), else one
# release back. It asks nothing, so it runs as well with no terminal, which is how the job runs it.
#
#   mybeast-deploy rollback --app demo --env staging -- examples/demo-rollback.sh
#   mybeast-deploy job --app demo --env staging --releases-dir examples/releases -- examples/demo-rollback.sh
#   ... -- examples/demo-rollback.sh --fail    (the switch fails: it ends with 1, as a real one must)
#   ... -- examples/demo-rollback.sh --hang    (it never ends: what the job's --timeout is for)
set -euo pipefail

say()  { printf '\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[31mxx  %s\033[0m\n' "$*" >&2; exit 1; }
trap 'exit 130' INT TERM

fail=0 hang=0
for arg in "$@"; do
    case $arg in --fail) fail=1 ;; --hang) hang=1 ;; esac
done

if [ -n "${RELEASE:-}" ]; then
    say "Rolling staging back to $RELEASE (the database stays as it is)"
else
    say "Rolling staging back one release (the database stays as it is)"
fi
sleep 1
if [ $hang = 1 ]; then
    info "waiting for the server to answer"
    while :; do sleep 1; done
fi
if [ $fail = 1 ]; then
    die "The domain could not be pointed at ${RELEASE:-the release before}: visitors still get what was live."
fi
info "pm2: demo-staging-queue online"
say "Done: ${RELEASE:-the earlier release} is live again"
