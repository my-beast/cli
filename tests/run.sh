#!/usr/bin/env bash
# The CLI's tests: mybeast-deploy against a stand-in of the service's API (tests/fake-service.php, php -S), in a
# throwaway git checkout. Run it with the bash the CLI must work with: `/bin/bash tests/run.sh` (3.2 on macOS).

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
CLI="$HERE/../mybeast-deploy"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/mybeast-deploy-tests.XXXXXX")
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

# A checkout to deploy from: one commit, on main.
REPO="$ROOT/repo"
mkdir -p "$REPO" && cd "$REPO" || exit 1
git init -q -b main . && git config user.name 'Anna Test' && git config user.email 'anna@example.test'
echo one >file && git add file && git -c commit.gpgsign=false commit -q -m 'Ship "the" thing'
SHA=$(git rev-parse HEAD)

fresh() { # a clean stand-in for the next test
    rm -rf "$ROOT/state" && mkdir -p "$ROOT/state"
}

deploy() { # the CLI as a person runs it, with settings in the environment and no config file
    env -u MYBEAST_DEPLOYS_KEY HOME="$ROOT/home" MYBEAST_DEPLOYS_CONFIG="$ROOT/none" MYBEAST_DEPLOY_TICK=0.2 \
        MYBEAST_DEPLOYS_URL="http://127.0.0.1:$PORT" MYBEAST_DEPLOYS_KEY="$KEY" "$CLI" "$@"
}

field() { # $1 file, $2 name → a value from the stand-in's JSON record
    php -r '$d = json_decode((string) file_get_contents($argv[1]), true); echo $d[$argv[2]] ?? "";' "$1" "$2"
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

# --- a good deploy: who, the commit, the output as it was, the end
fresh
out=$(deploy run --app demo --env staging -- sh -c 'printf "\033[1m==> Building r1\033[0m\n"; echo "two words"; printf "no newline at the end"' 2>"$ROOT/err")
code=$?
check 'a good deploy ends 0' same "$code" 0
check 'the output reaches the terminal' same "$out" "$(printf '\033[1m==> Building r1\033[0m\ntwo words\nno newline at the end')"
check 'the whole output reaches the service, byte for byte' same "$(cat "$ROOT/state/log")" "$(printf '\033[1m==> Building r1\033[0m\ntwo words\nno newline at the end')"
check 'app' same "$(field "$ROOT/state/started.json" app)" demo
check 'environment' same "$(field "$ROOT/state/started.json" environment)" staging
check 'kind' same "$(field "$ROOT/state/started.json" kind)" deploy
check 'commit' same "$(field "$ROOT/state/started.json" commit)" "$SHA"
check 'commit subject' same "$(field "$ROOT/state/started.json" commit_subject)" 'Ship "the" thing'
check 'branch' same "$(field "$ROOT/state/started.json" branch)" main
check 'a clean checkout' same "$(field "$ROOT/state/started.json" dirty)" 0
check 'who' same "$(field "$ROOT/state/started.json" actor_name)" 'Anna Test'
check 'their e-mail' same "$(field "$ROOT/state/started.json" actor_email)" anna@example.test
check 'the machine' same "$(field "$ROOT/state/started.json" machine)" "$(hostname -s 2>/dev/null || uname -n)"
check 'the command as typed' has "$(field "$ROOT/state/started.json" command)" "sh -c printf"
check 'finished as succeeded' same "$(field "$ROOT/state/finished.json" status)" succeeded
check 'exit code 0' same "$(field "$ROOT/state/finished.json" exit_code)" 0
check 'it says where to look' has "$(cat "$ROOT/err")" 'Deploy #1 of demo to staging: http://deploys.test/projects/p/apps/demo/deploys/1'
check 'and how it ended' has "$(cat "$ROOT/err")" 'Deploy #1 succeeded in 3s, release abc123'

# --- a failed one keeps its own exit code; uncommitted changes are said
fresh
echo changed >>"$REPO/file"
deploy run --app demo --env staging -- sh -c 'echo boom >&2; exit 3' >/dev/null 2>&1
code=$?
git -C "$REPO" checkout -q file
check 'a failed deploy ends with the command'"'"'s code' same "$code" 3
check 'its stderr is in the log' same "$(cat "$ROOT/state/log")" boom
check 'finished as failed' same "$(field "$ROOT/state/finished.json" status)" failed
check 'exit code 3' same "$(field "$ROOT/state/finished.json" exit_code)" 3
check 'uncommitted changes' same "$(field "$ROOT/state/started.json" dirty)" 1

# --- a batch whose answer is lost is sent again, and the service keeps it once
fresh
touch "$ROOT/state/lose-lines-once"
deploy run --app demo --env staging -- sh -c 'for i in 1 2 3; do echo "line $i"; sleep 0.3; done' >/dev/null 2>&1
check 'resent, not doubled' same "$(cat "$ROOT/state/log")" "$(printf 'line 1\nline 2\nline 3')"
check 'it was sent more than once' [ "$(wc -l <"$ROOT/state/batches" | tr -d ' ')" -ge 2 ]

# --- a long log goes in batches of at most 256 KB, all of it
fresh
deploy run --app demo --env staging -- sh -c 'i=0; while [ $i -lt 6000 ]; do echo "a long line of the deploy number $i, padded so the log is bigger than one batch ......"; i=$((i+1)); done' >/dev/null 2>&1
check 'every line arrived' same "$(wc -l <"$ROOT/state/log" | tr -d ' ')" 6000
check 'more than one batch' [ "$(wc -l <"$ROOT/state/batches" | tr -d ' ')" -ge 3 ]
check 'none over 256 KB' [ "$(sort -n "$ROOT/state/batches" | tail -1)" -le 262144 ]

# --- secrets: a secret on the command line is not sent, and the command never sees the key
fresh
out=$(deploy run --app demo --env staging -- env DEPLOY_PASSWORD=hunter2 sh -c 'echo "key: ${MYBEAST_DEPLOYS_KEY:-none} id: ${MYBEAST_DEPLOY_ID:-none}"' 2>/dev/null)
check 'the command never gets the key' same "$out" 'key: none id: 01a17d00-0000-7000-8000-000000000001'
check 'a secret value is not sent' same "$(field "$ROOT/state/started.json" command)" 'env DEPLOY_PASSWORD=… sh -c echo\ \"key:\ \$\{MYBEAST_DEPLOYS_KEY:-none\}\ id:\ \$\{MYBEAST_DEPLOY_ID:-none\}\"'
check 'nor anywhere in what was sent' [ -z "$(grep -rl hunter2 "$ROOT/state")" ]

# --- a rollback to a named release hands the script RELEASE
fresh
out=$(deploy rollback --app demo --env staging --to 20261026-101010-abc1234 -- sh -c 'echo "RELEASE=$RELEASE"' 2>/dev/null)
check 'the script gets RELEASE' same "$out" 'RELEASE=20261026-101010-abc1234'
check 'kind rollback' same "$(field "$ROOT/state/started.json" kind)" rollback
check 'rollback_to' same "$(field "$ROOT/state/started.json" rollback_to)" 20261026-101010-abc1234

# --- without a command: the app's own, after a yes (none without a terminal)
fresh
printf '%s' '{"app":"demo","name":"Demo","environment":"staging","deploy_command":"echo \"the app'"'"'s own\" for staging","rollback_command":"echo back"}' >"$ROOT/state/app.json"
deploy run --app demo --env staging </dev/null >"$ROOT/out" 2>"$ROOT/err"
code=$?
check 'no terminal, no --yes: nothing is run' same "$code" 2
check 'and it says why' has "$(cat "$ROOT/err")" 'pass --yes'
check 'nothing was reported' [ ! -e "$ROOT/state/started.json" ]
out=$(deploy run --app demo --env staging --yes 2>"$ROOT/err")
check 'with --yes the app'"'"'s command runs' same "$out" "the app's own for staging"
check 'and is shown first' has "$(cat "$ROOT/err")" "demo's deploy command for staging: echo \"the app's own\" for staging"
check 'and sent as it reads' same "$(field "$ROOT/state/started.json" command)" "echo \"the app's own\" for staging"

# --- the service down: the deploy runs all the same, unreported
fresh
touch "$ROOT/state/down"
out=$(deploy run --app demo --env staging -- sh -c 'echo still deploying; exit 4' 2>"$ROOT/err")
code=$?
check 'it runs' same "$out" 'still deploying'
check 'with its own code' same "$code" 4
check 'and says it was not reported' has "$(cat "$ROOT/err")" 'not reported:'

# --- a warning from the service is passed on
fresh
touch "$ROOT/state/warn"
deploy run --app demo --env staging -- true >/dev/null 2>"$ROOT/err"
check 'the note' has "$(cat "$ROOT/err")" 'note: Deploy #0 by "Bo" is still running here'

# --- a bad key, a bad setting, a bad name
fresh
env HOME="$ROOT/home" MYBEAST_DEPLOYS_CONFIG="$ROOT/none" MYBEAST_DEPLOYS_URL="http://127.0.0.1:$PORT" MYBEAST_DEPLOYS_KEY='sk_wrong.wrong' \
    "$CLI" run --app demo --env staging -- echo ran >"$ROOT/out" 2>"$ROOT/err"
check 'a wrong key: still runs' same "$(cat "$ROOT/out")" ran
check 'and says the key was refused' has "$(cat "$ROOT/err")" 'the key was refused'
env HOME="$ROOT/home" MYBEAST_DEPLOYS_CONFIG="$ROOT/none" MYBEAST_DEPLOYS_URL="http://example.com" MYBEAST_DEPLOYS_KEY="$KEY" \
    "$CLI" run --app demo --env staging -- echo ran >"$ROOT/out" 2>"$ROOT/err"
check 'plain http elsewhere is refused before anything runs' same "$(cat "$ROOT/out")" ''
deploy run --app Demo --env staging -- echo ran >"$ROOT/out" 2>&1
check 'a bad app name is refused' has "$(cat "$ROOT/out")" '--app: lower-case'

# --- settings from the config file, which must be private
fresh
mkdir -p "$ROOT/home/.config/mybeast"
printf 'MYBEAST_DEPLOYS_URL=http://127.0.0.1:%s\nexport MYBEAST_DEPLOYS_KEY="%s"\n' "$PORT" "$KEY" >"$ROOT/home/.config/mybeast/deploys.env"
chmod 644 "$ROOT/home/.config/mybeast/deploys.env"
env -u MYBEAST_DEPLOYS_URL -u MYBEAST_DEPLOYS_KEY -u MYBEAST_DEPLOYS_CONFIG HOME="$ROOT/home" XDG_CONFIG_HOME= MYBEAST_DEPLOY_TICK=0.2 \
    "$CLI" run --app demo --env staging -- echo from-file >"$ROOT/out" 2>"$ROOT/err"
check 'a file others can read is refused' has "$(cat "$ROOT/err")" 'can be read by others'
chmod 600 "$ROOT/home/.config/mybeast/deploys.env"
env -u MYBEAST_DEPLOYS_URL -u MYBEAST_DEPLOYS_KEY -u MYBEAST_DEPLOYS_CONFIG HOME="$ROOT/home" XDG_CONFIG_HOME= MYBEAST_DEPLOY_TICK=0.2 \
    "$CLI" run --app demo --env staging -- echo from-file >"$ROOT/out" 2>"$ROOT/err"
check 'the settings come from the file' same "$(field "$ROOT/state/finished.json" status)" succeeded

# --- status
fresh
printf '%s' '{"app":"demo","name":"Demo","environment":"staging","deploy_command":"make deploy:staging","rollback_command":"make rollback:staging","live_release":"r7","live_commit":"a1b2c3d4","live_title":"Deploy #4","live_by":"Anna","live_at":"27.10. 14:02 (3 minutes ago)","last_status":"succeeded"}' >"$ROOT/state/app.json"
out=$(deploy status --app demo --env staging 2>&1)
check 'status says what is live' has "$out" 'live on staging: r7 - Deploy #4, by Anna, 27.10. 14:02 (3 minutes ago)'
check 'and the commands' has "$out" 'rollback command: make rollback:staging'

printf '%s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" = 0 ]
