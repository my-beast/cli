#!/usr/bin/env bash
# A stand-in deploy for trying mybeast-deploy: it talks like a typical deploy/deploy.sh (`==>` steps
# in bold, warnings in yellow, a progress bar redrawn with \r) and deploys nothing.
#
#   mybeast-deploy run --app demo --env staging -- deploys/cli/examples/demo-deploy.sh
#   mybeast-deploy run --app demo --env staging -- deploys/cli/examples/demo-deploy.sh --fail
#   ... -- deploys/cli/examples/demo-deploy.sh --ask       (asks for a "deploy password" first, on the terminal)
set -euo pipefail

say()  { printf '\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[33m!!  %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[31mxx  %s\033[0m\n' "$*" >&2; exit 1; }
trap 'exit 130' INT TERM

fail=0 ask=0
for arg in "$@"; do
    case $arg in --fail) fail=1 ;; --ask) ask=1 ;; esac
done

if [ $ask = 1 ]; then
    IFS= read -r -s -p "Deploy password: " password </dev/tty
    echo >&2
    [ -n "$password" ] || die "Wrong password."
fi

sha=$(git rev-parse --short HEAD 2>/dev/null || echo 0000000)
release="$(date +%Y%m%d-%H%M%S)-$sha"
[ -z "$(git status --porcelain 2>/dev/null | head -1)" ] || release="$release-wip"
started=$SECONDS

say "Checking the server"
info "the deploy key logs in; port 3140 is ours"
sleep 1
say "Building $release"
for pct in 10 25 40 60 80 100; do
    printf '\r    vite build %3s%%' "$pct"
    sleep 0.3
done
printf '\n'
info "$(( RANDOM % 900 + 100 )) KB → deploy/.build/$release.tar.gz"
say "Uploading"
sleep 1
say "Installing on the server (database check, unpack, migrate, cache)"
info "Migrating: 2026_10_27_000001_create_demo_table"
sleep 1
if [ $fail = 1 ]; then
    warn "SQLSTATE[42S01]: Base table or view already exists: 1050 Table 'demo' already exists"
    die "migrate --force failed on $release: visitors still get the release before."
fi
say "Switching to $release"
sleep 1
say "Done: $release is live in $(( (SECONDS - started) / 60 ))m $(( (SECONDS - started) % 60 ))s"
