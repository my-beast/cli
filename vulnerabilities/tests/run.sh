#!/usr/bin/env bash
# The CLI's tests: mybeast-vulnerabilities against a stand-in of the service's API (tests/fake-service.php, php -S), in
# a throwaway git checkout laid out both ways an app may be (lock files at the top, or in backend/ and frontend/). Run
# it with the bash the CLI must work with: `/bin/bash tests/run.sh` (3.2 on macOS).

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
CLI="$HERE/../mybeast-vulnerabilities"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/mybeast-vulnerabilities-tests.XXXXXX")
KEY='sk_testkey000000001.secret-secret-secret-secret-secret-secret-123'
PASSED=0 FAILED=0 SERVER=

finish() {
    [ -z "$SERVER" ] || { kill "$SERVER" 2>/dev/null; wait "$SERVER" 2>/dev/null; }
    rm -rf "$ROOT"
}
trap finish EXIT

# A free port for the stand-in.
PORT=$((20000 + RANDOM % 9000))
while curl --silent --max-time 1 "http://127.0.0.1:$PORT/" >/dev/null 2>&1; do PORT=$((PORT + 1)); done
mkdir -p "$ROOT/state"
FAKE_STATE="$ROOT/state" php -S "127.0.0.1:$PORT" "$HERE/fake-service.php" >"$ROOT/server.log" 2>&1 &
SERVER=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do curl --silent --max-time 1 "http://127.0.0.1:$PORT/" >/dev/null 2>&1 && break; sleep 0.2; done

# A checkout to push from: lock files at the top, and a backend/ and frontend/ as my-beast.com has them.
REPO="$ROOT/repo"
mkdir -p "$REPO/backend" "$REPO/frontend" "$REPO/empty" && cd "$REPO" || exit 1
git init -q -b main . && git config user.name 'Anna Test' && git config user.email 'anna@example.test'
printf '{"packages": [{"name": "acme/a", "version": "1.0.0"}], "packages-dev": []}\n' >composer.lock
printf '{"require": {"acme/a": "^1.0"}}\n' >composer.json
printf '{"lockfileVersion": 3, "packages": {"": {}, "node_modules/b": {"version": "2.0.0"}}}\n' >package-lock.json
printf '{"packages": [{"name": "acme/back", "version": "3.0.0"}]}\n' >backend/composer.lock
printf '{"require": {"acme/back": "^3.0"}}\n' >backend/composer.json
printf '{"lockfileVersion": 2, "packages": {"": {}, "node_modules/front": {"version": "4.0.0"}}}\n' >"frontend/package-lock.json"
git add . && git -c commit.gpgsign=false commit -q -m 'Lock files'
SHA=$(git rev-parse HEAD)

fresh() { # a clean stand-in for the next test
    rm -rf "$ROOT/state" && mkdir -p "$ROOT/state"
}

cli() { # the CLI as a CI job runs it, with settings in the environment and no config file
    env -u MYBEAST_VULNERABILITIES_KEY -u GITHUB_SHA -u CI_COMMIT_SHA HOME="$ROOT/home" MYBEAST_VULNERABILITIES_CONFIG="$ROOT/none" \
        MYBEAST_VULNERABILITIES_URL="http://127.0.0.1:$PORT" MYBEAST_VULNERABILITIES_SECRET="$KEY" "$CLI" "$@"
}

field() { # $1 file, $2 name → a value from the stand-in's JSON record
    php -r '$d = json_decode((string) file_get_contents($argv[1]), true); $v = $d; foreach (explode(".", $argv[2]) as $k) { $v = $v[$k] ?? ""; } echo is_array($v) ? json_encode($v) : $v;' "$1" "$2"
}

check() { # $1 what, then a condition
    local what=$1
    shift
    if "$@"; then
        PASSED=$((PASSED + 1))
    else
        FAILED=$((FAILED + 1))
        printf 'FAILED: %s\n' "$what" >&2
    fi
}

same() { [ "$1" = "$2" ] || { printf '    expected: %q\n    got:      %q\n' "$2" "$1" >&2; return 1; }; }
has() { case $1 in *"$2"*) return 0 ;; esac; printf '    %q\n    does not hold %q\n' "$1" "$2" >&2; return 1; }
lacks() { case $1 in *"$2"*) printf '    %q\n    holds %q\n' "$1" "$2" >&2; return 1 ;; esac; return 0; }

# --- a push from the app's folder: the lock files there, the commit, byte for byte
fresh
out=$(cli push --app shop --env production 2>"$ROOT/err")
code=$?
check 'a push ends 0' same "$code" 0
check 'app' same "$(field "$ROOT/state/fields.json" app)" shop
check 'environment' same "$(field "$ROOT/state/fields.json" environment)" production
check 'commit' same "$(field "$ROOT/state/fields.json" commit)" "$SHA"
check 'branch' same "$(field "$ROOT/state/fields.json" branch)" main
check 'client' same "$(field "$ROOT/state/fields.json" client)" mybeast-vulnerabilities/1
check 'composer.lock as it is' same "$(cat "$ROOT/state/files/composer-0-lock")" "$(cat composer.lock)"
check 'its composer.json beside it' same "$(cat "$ROOT/state/files/composer-0-json")" "$(cat composer.json)"
check 'package-lock.json as it is' same "$(cat "$ROOT/state/files/npm-0-lock")" "$(cat package-lock.json)"
check 'under their own names' same "$(field "$ROOT/state/names.json" composer-0-lock)$(field "$ROOT/state/names.json" npm-0-lock)" 'composer.lockpackage-lock.json'
check 'and where they were read' same "$(field "$ROOT/state/fields.json" composer.0.path) $(field "$ROOT/state/fields.json" npm.0.path)" 'composer.lock package-lock.json'
check 'nothing open is said' has "$out" 'Nothing open.'
check 'what was taken' has "$out" "shop · production: 417 packages from ${SHA:0:7}, 2 lock files; 2 new, 1 fixed since the last push."
check 'and the page' has "$out" 'http://vulnerabilities.test/projects/p/apps/shop/production'

# --- my-beast.com's layout: named lock files, each composer.lock with the composer.json beside it
fresh
cli push --app my-beast --env production --lock backend/composer.lock --lock frontend/package-lock.json >/dev/null 2>"$ROOT/err"
check 'the backend lock' same "$(cat "$ROOT/state/files/composer-0-lock")" "$(cat backend/composer.lock)"
check 'with the backend composer.json' same "$(cat "$ROOT/state/files/composer-0-json")" "$(cat backend/composer.json)"
check 'the frontend lock' same "$(cat "$ROOT/state/files/npm-0-lock")" "$(cat frontend/package-lock.json)"
check 'paths as given' same "$(field "$ROOT/state/fields.json" composer.0.path) $(field "$ROOT/state/fields.json" npm.0.path)" 'backend/composer.lock frontend/package-lock.json'
check 'nothing else' same "$(ls "$ROOT/state/files" | tr '\n' ' ')" 'composer-0-json composer-0-lock npm-0-lock '

# --- what is open, and --fail-on for CI
fresh
printf '%s' '{"critical":0,"high":1,"medium":2,"low":0,"unrated":1}' >"$ROOT/state/findings.json"
printf 'HIGH      acme/http-client v2.3.0  CVE-2026-1001 (GHSA-fx01)  fixed in 2.4.1\nMEDIUM    b 2.0.0  GHSA-x  "quoted" \\ fixed in 2.0.1, through another package\n' >"$ROOT/state/report.txt"
out=$(cli push --app shop --env production 2>"$ROOT/err")
check 'without --fail-on it ends 0' same "$?" 0
check 'it counts what is open' has "$out" '4 open: 1 high, 2 medium, 1 not rated'
check 'one line each' has "$out" '  HIGH      acme/http-client v2.3.0  CVE-2026-1001 (GHSA-fx01)  fixed in 2.4.1'
check 'quotes and backslashes as they were' has "$out" '  MEDIUM    b 2.0.0  GHSA-x  "quoted" \ fixed in 2.0.1, through another package'
cli push --app shop --env production --fail-on high >/dev/null 2>"$ROOT/err"
check '--fail-on high with a high open ends 1' same "$?" 1
check 'and says why' has "$(cat "$ROOT/err")" 'a finding at high or worse is open (--fail-on high)'
cli push --app shop --env production --fail-on critical >/dev/null 2>&1
check '--fail-on critical with none critical ends 0' same "$?" 0
cli push --app shop --env production --fail-on low >/dev/null 2>&1
check '--fail-on low with a medium open ends 1' same "$?" 1
cli push --app shop --env production --fail-on severe >/dev/null 2>"$ROOT/err"
check 'an unknown severity is its own refusal' same "$?" 2

# --- status: the last push, without pushing
fresh
printf '%s' '{"critical":1,"high":0,"medium":0,"low":0,"unrated":0}' >"$ROOT/state/findings.json"
out=$(cli status --app shop --env production --fail-on high 2>"$ROOT/err")
code=$?
check 'status with a critical open and --fail-on high ends 1' same "$code" 1
check 'status says when and what' has "$out" 'shop · production: last pushed 2026-10-27T12:00:00+00:00 from abcdef1, 417 packages.'
check 'status sent nothing' same "$(grep -c '^POST' "$ROOT/state/requests" 2>/dev/null || true)" 0
cli status --app shop --env staging >/dev/null 2>"$ROOT/err"
check 'no push there yet ends 3' same "$?" 3
check 'and says so' has "$(cat "$ROOT/err")" 'shop has pushed nothing to staging yet.'

# --- the secret never on a command line: curl gets it on its standard input
fresh
mkdir -p "$ROOT/shim"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/curl-args"\nexec "%s" "$@"\n' "$ROOT/state" "$(command -v curl)" >"$ROOT/shim/curl"
chmod +x "$ROOT/shim/curl"
PATH="$ROOT/shim:$PATH" cli push --app shop --env production >/dev/null 2>&1
check 'curl ran' [ -s "$ROOT/state/curl-args" ]
check 'without the secret in its arguments' lacks "$(cat "$ROOT/state/curl-args")" 'secret-secret'

# --- refusals: no lock file, a wrong name, a bad answer, the service down, a wrong secret
fresh
(cd "$REPO/empty" && cli push --app shop --env production >/dev/null 2>"$ROOT/err")
check 'no lock file here ends 2' same "$?" 2
check 'and says where it looked' has "$(cat "$ROOT/err")" 'no composer.lock or package-lock.json here'
check 'nothing was sent' [ ! -e "$ROOT/state/requests" ]
cli push --app shop --env production --lock yarn.lock >/dev/null 2>"$ROOT/err"
check 'a lock file it does not read' has "$(cat "$ROOT/err")" '--lock yarn.lock: no such file'
touch "$REPO/yarn.lock"
cli push --app shop --env production --lock yarn.lock >/dev/null 2>"$ROOT/err"
check 'yarn is not read yet' has "$(cat "$ROOT/err")" 'yarn and pnpm are not read yet'
rm "$REPO/yarn.lock"
cli push --app Shop --env production >/dev/null 2>"$ROOT/err"
check 'a bad app name' has "$(cat "$ROOT/err")" '--app: lower-case'
printf 'package-lock.json is lockfileVersion 1: only 2 and 3 are read.' >"$ROOT/state/refuse"
cli push --app shop --env production >/dev/null 2>"$ROOT/err"
check 'a refusal ends 3' same "$?" 3
check 'and passes on its word' has "$(cat "$ROOT/err")" '422: package-lock.json is lockfileVersion 1: only 2 and 3 are read.'
rm "$ROOT/state/refuse" && touch "$ROOT/state/down"
cli push --app shop --env production >/dev/null 2>"$ROOT/err"
check 'the service down ends 3' same "$?" 3
check 'and says it was not sent' has "$(cat "$ROOT/err")" 'not sent:'
rm "$ROOT/state/down"
env HOME="$ROOT/home" MYBEAST_VULNERABILITIES_CONFIG="$ROOT/none" MYBEAST_VULNERABILITIES_URL="http://127.0.0.1:$PORT" MYBEAST_VULNERABILITIES_SECRET='sk_wrong.wrong' \
    "$CLI" push --app shop --env production >/dev/null 2>"$ROOT/err"
check 'a wrong secret' has "$(cat "$ROOT/err")" 'the secret was refused'
env HOME="$ROOT/home" MYBEAST_VULNERABILITIES_CONFIG="$ROOT/none" MYBEAST_VULNERABILITIES_URL="http://example.com" MYBEAST_VULNERABILITIES_SECRET="$KEY" \
    "$CLI" push --app shop --env production >/dev/null 2>"$ROOT/err"
check 'plain http elsewhere is refused' has "$(cat "$ROOT/err")" 'must be https://'

# --- settings from the config file, which must be private; the _KEY name works too
fresh
mkdir -p "$ROOT/home/.config/mybeast"
printf 'MYBEAST_VULNERABILITIES_URL=http://127.0.0.1:%s\nexport MYBEAST_VULNERABILITIES_KEY="%s"\n' "$PORT" "$KEY" >"$ROOT/home/.config/mybeast/vulnerabilities.env"
chmod 644 "$ROOT/home/.config/mybeast/vulnerabilities.env"
env -u MYBEAST_VULNERABILITIES_URL -u MYBEAST_VULNERABILITIES_SECRET -u MYBEAST_VULNERABILITIES_KEY -u MYBEAST_VULNERABILITIES_CONFIG HOME="$ROOT/home" XDG_CONFIG_HOME= \
    "$CLI" push --app shop --env production >/dev/null 2>"$ROOT/err"
check 'a file others can read is refused' has "$(cat "$ROOT/err")" 'can be read by others'
chmod 600 "$ROOT/home/.config/mybeast/vulnerabilities.env"
env -u MYBEAST_VULNERABILITIES_URL -u MYBEAST_VULNERABILITIES_SECRET -u MYBEAST_VULNERABILITIES_KEY -u MYBEAST_VULNERABILITIES_CONFIG HOME="$ROOT/home" XDG_CONFIG_HOME= \
    "$CLI" push --app shop --env production >/dev/null 2>"$ROOT/err"
check 'the settings come from the file' same "$(field "$ROOT/state/fields.json" app)" shop

# --- outside a checkout: the CI's commit
fresh
cp composer.lock composer.json "$ROOT/home/"
(cd "$ROOT/home" && env GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 HOME="$ROOT/home" MYBEAST_VULNERABILITIES_CONFIG="$ROOT/none" \
    MYBEAST_VULNERABILITIES_URL="http://127.0.0.1:$PORT" MYBEAST_VULNERABILITIES_SECRET="$KEY" GIT_CEILING_DIRECTORIES="$ROOT" "$CLI" push --app shop --env production >/dev/null 2>&1)
check 'the commit from CI' same "$(field "$ROOT/state/fields.json" commit)" 0123456789abcdef0123456789abcdef01234567

printf '%s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" = 0 ]
