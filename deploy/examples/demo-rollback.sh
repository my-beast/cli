#!/usr/bin/env bash
# A stand-in rollback for trying mybeast-deploy rollback, in the words of a typical `make rollback:staging`. Goes back
# to RELEASE when it is given (mybeast-deploy rollback --to <release> hands it over), else one release back.
#
#   mybeast-deploy rollback --app demo --env staging -- examples/demo-rollback.sh
set -euo pipefail

say()  { printf '\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
trap 'exit 130' INT TERM

if [ -n "${RELEASE:-}" ]; then
    say "Rolling staging back to $RELEASE (the database stays as it is)"
else
    say "Rolling staging back one release (the database stays as it is)"
fi
sleep 1
info "pm2: demo-staging-queue online"
say "Done: the earlier release is live again"
