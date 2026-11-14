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
check 'its last commits' same "$(field "$ROOT/state/started.json" commits)" "$SHA"$'\t''Anna Test'$'\t''Ship "the" thing'
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

# ------------------------------------------------------------------------------------------------------- the job
# `mybeast-deploy job` as cron runs it: a job key, a folder of its own for what it keeps ($ROOT/job), three releases
# on the disk. The stand-in hands out what state/request.json says. A command that touches $ROOT/ran shows what ran.

JOB_KEY='jk_testkey000000001.secret-secret-secret-secret-secret-secret-123'
REQUEST='0193a5c0-0000-7000-8000-00000000000a'
RUN='01a17d00-0000-7000-8000-000000000001'
PAGE='http://deploys.test/projects/p/apps/demo/deploys/1'
HERE="http://127.0.0.1:$PORT"
JOB="$ROOT/job/demo-staging"
ENTRY="$JOB/journal/$REQUEST"

mkdir -p "$ROOT/releases/v3.11.3" "$ROOT/releases/v3.11.4" "$ROOT/releases/v3.12.1" "$ROOT/releases/.tmp" "$ROOT/releases/not a release" "$ROOT/empty"
: >"$ROOT/releases/v9.9.9"

cron() { # the CLI with the job's settings in the environment and no config file; SERVER_KEY adds a server key to them
    env -u MYBEAST_DEPLOYS_KEY -u MYBEAST_DEPLOYS_JOB_KEY -u JOB_KEY -u JOB_URL -u SERVER_KEY -u REQUEST_ID \
        HOME="$ROOT/home" MYBEAST_DEPLOYS_CONFIG="$ROOT/none" MYBEAST_DEPLOY_TICK=0.2 MYBEAST_DEPLOYS_STATE="$ROOT/job" \
        MYBEAST_DEPLOYS_URL="${JOB_URL:-$HERE}" MYBEAST_DEPLOYS_JOB_KEY="$JOB_KEY" ${SERVER_KEY:+MYBEAST_DEPLOYS_KEY="$SERVER_KEY"} "$CLI" "$@"
}

job() { # the job for demo in staging, with the releases of $ROOT/releases
    cron job --app demo --env staging --releases-dir "$ROOT/releases" "$@"
}

anew() { # a clean stand-in, and a job that has kept nothing
    fresh
    rm -rf "$ROOT/job" "$ROOT/ran" "$ROOT/pid"
}

waits() { # a request waits at the stand-in: $1 its release, $2 more of its JSON
    printf '{"request":"%s","release":"%s","asked_by":"Ruis"%s}' "${REQUEST_ID:-$REQUEST}" "$1" "${2:-}" >"$ROOT/state/request.json"
}

count() { # $1 a file of the stand-in's → how many lines it has (none when it is not there)
    if [ -e "$ROOT/state/$1" ]; then wc -l <"$ROOT/state/$1" | tr -d ' '; else printf 0; fi
}

lacks() { case $1 in *"$2"*) printf '    %q\n    holds %q\n' "$1" "$2" >&2; return 1 ;; esac; return 0; }
absent() { [ ! -e "$1" ] || { printf '    %q is there\n' "$1" >&2; return 1; }; }
gone() { # $1 a pid or -pgid → true once nothing answers to it (it is given 8 s)
    local i=0
    while kill -0 -- "$1" 2>/dev/null; do i=$((i + 1)); [ $i -le 40 ] || break; sleep 0.2; done
    [ $i -gt 40 ] || return 0
    printf '    %s still runs\n' "$1" >&2
    return 1
}
until_there() { # $1 a file → true once it is there (it is given 10 s)
    local i=0
    while [ ! -s "$1" ]; do i=$((i + 1)); [ $i -le 100 ] || return 1; sleep 0.1; done
}

# --- the stand-in keeps the two keys apart
check 'a server key at the job'"'"'s door is refused' same "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $KEY" "$HERE/api/v1/job/ask")" 401
check 'a job key at the server'"'"'s door is refused' same "$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $JOB_KEY" "$HERE/api/v1/deploys")" 401

# --- nothing waits: the pulse, and not a word
anew
out=$(job -- touch "$ROOT/ran" 2>&1)
code=$?
check 'nothing waits: it ends 0' same "$code" 0
check 'and says nothing' same "$out" ''
check 'the pulse names the machine' same "$(field "$ROOT/state/asked.json" machine)" "$(hostname -s 2>/dev/null || uname -n)"
check 'and the releases it keeps: folders only, the last by name first' same "$(field "$ROOT/state/asked.json" releases)" "$(printf 'v3.12.1\nv3.11.4\nv3.11.3')"
check 'and its version' same "$(field "$ROOT/state/asked.json" cli_version)" 3
check 'it is no check' same "$(field "$ROOT/state/asked.json" check)" ''
check 'one call, to ask' same "$(cat "$ROOT/state/requests")" 'POST /api/v1/job/ask '
check 'nothing was run' absent "$ROOT/ran"
check 'the lock is given back' absent "$JOB/lock"
check 'its folder is its owner'"'"'s only' same "$(find "$JOB" -prune \( -perm -004 -o -perm -040 \))" ''

# --- a request: the command gets RELEASE, its output arrives byte for byte, the run is reported in the spec's words
anew
waits v3.11.4
out=$(echo 'typed at the prompt' | job -- sh -c 'printf "\033[1m==> Back to $RELEASE\033[0m\n"; echo "run $MYBEAST_DEPLOY_ID for $MYBEAST_ROLLBACK_REQUEST at $MYBEAST_DEPLOY_PAGE"; cat; printf "no newline at the end"' 2>"$ROOT/err")
code=$?
expected=$(printf '\033[1m==> Back to v3.11.4\033[0m\nrun %s for %s at %s\nno newline at the end' "$RUN" "$REQUEST" "$PAGE")
check 'a request: it ends with the command'"'"'s 0' same "$code" 0
check 'the command gets RELEASE and what it is part of, and nothing to read' same "$out" "$expected"
check 'the whole output reaches the service, byte for byte' same "$(cat "$ROOT/state/log")" "$expected"
check 'it says whose request it took, where to look and how it ended, and no more' same "$(cat "$ROOT/err")" "mybeast-deploy: took Ruis's request: roll back demo in staging to v3.11.4
mybeast-deploy: Rollback #1 of demo in staging: $PAGE
mybeast-deploy: Rollback #1 succeeded in 3s, release v3.11.4: $PAGE"
check 'the start names the request' same "$(field "$ROOT/state/job-started.json" request)" "$REQUEST"
check 'and the job'"'"'s own command' has "$(field "$ROOT/state/job-started.json" command)" 'sh -c printf'
check 'and the machine' same "$(field "$ROOT/state/job-started.json" machine)" "$(hostname -s 2>/dev/null || uname -n)"
check 'finished as succeeded' same "$(field "$ROOT/state/finished.json" status)" succeeded
check 'exit code 0' same "$(field "$ROOT/state/finished.json" exit_code)" 0
check 'the finish names no release: the log'"'"'s word wins' same "$(field "$ROOT/state/finished.json" release)" ''
check 'the app'"'"'s commands were never read' same "$(grep -c '/api/v1/apps' "$ROOT/state/requests")" 0
check 'the journal closed the request' [ -e "$ENTRY/closed" ]
check 'and let its log go' absent "$ENTRY/log"

# --- who asked is the service's word: it is printed short
long=$(printf 'N%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63 64 65 66 67 68 69 70 71 72 73 74 75 76 77 78 79 80)
anew
printf '{"request":"%s","release":"v3.11.4","asked_by":"%sand more"}' "$REQUEST" "$long" >"$ROOT/state/request.json"
out=$(job -- true 2>&1)
check 'a name of more than 80 characters is cut to 80' has "$out" "mybeast-deploy: took $long's request: roll back demo in staging to v3.11.4"

# --- the same request handed out again is not run twice
anew
waits v3.11.4
job -- true >/dev/null 2>&1
rm "$ROOT/state/request-closed" "$ROOT/state/job-started.json"
out=$(job -- touch "$ROOT/ran" 2>&1)
check 'a request it closed before is refused' has "$out" 'not run: the job closed this request before, and does not run one twice. Deploys was told.'
check 'and not run again' absent "$ROOT/ran"

# --- a failing command keeps its exit code
anew
waits v3.11.4
job -- sh -c 'echo broke >&2; exit 3' >/dev/null 2>&1
code=$?
check 'a failed rollback ends with the command'"'"'s code' same "$code" 3
check 'its stderr is in the log' same "$(cat "$ROOT/state/log")" broke
check 'finished as failed' same "$(field "$ROOT/state/finished.json" status)" failed
check 'exit code 3' same "$(field "$ROOT/state/finished.json" exit_code)" 3

# --- the command never sees a key, whichever is in the job's own environment
anew
waits v3.11.4
out=$(SERVER_KEY="$KEY" job -- sh -c 'env | grep -e MYBEAST -e RELEASE -e testkey | sort' 2>/dev/null)
check 'the command ran, with RELEASE' has "$out" 'RELEASE=v3.11.4'
check 'and the settings that are no secret' has "$out" "MYBEAST_DEPLOYS_URL=$HERE"
check 'it has no job key' lacks "$out" 'jk_'
check 'nor a server key' lacks "$out" 'sk_'
check 'nor their names' lacks "$out" '_KEY'
check 'and none reached the service in its log' lacks "$(cat "$ROOT/state/log")" 'testkey'

# --- a release this machine does not keep, or no release's name at all, is refused with why; nothing runs
anew
waits v3.10.0
out=$(job -- touch "$ROOT/ran" 2>&1)
code=$?
check 'a release not in the list: said in the spec'"'"'s words' same "$out" "mybeast-deploy: not run: v3.10.0 is not in $ROOT/releases any more. Deploys was told."
check 'it ends 0: the job did its work' same "$code" 0
check 'Deploys is told why' same "$(field "$ROOT/state/refused.json" why)" 'v3.10.0 is not kept on this server any more'
check 'nothing was run' absent "$ROOT/ran"
check 'nothing was started' same "$(count starts)" 0
check 'and nothing is kept of it' absent "$ENTRY"

anew
waits v9.9.9
job -- touch "$ROOT/ran" >/dev/null 2>&1
check 'a file is no release' same "$(field "$ROOT/state/refused.json" why)" 'v9.9.9 is not kept on this server any more'
check 'nothing was run' absent "$ROOT/ran"

anew
waits ..
out=$(job -- touch "$ROOT/ran" 2>&1)
check 'a release of ..: refused' has "$out" 'not run: Deploys named a release the job does not take ("..")'
check 'Deploys is told why' has "$(field "$ROOT/state/refused.json" why)" "the release's name is not one the job takes"
check 'nothing was run' absent "$ROOT/ran"
check 'nothing was started' same "$(count starts)" 0

anew
mkdir -p "$ROOT/releases/-rf"
waits -rf
out=$(job -- touch "$ROOT/ran" 2>&1)
rmdir "$ROOT/releases/-rf"
check 'a leading dash: refused, even with such a folder on the disk' has "$out" 'not run: Deploys named a release the job does not take ("-rf")'
check 'Deploys is told why' has "$(field "$ROOT/state/refused.json" why)" "the release's name is not one the job takes"
check 'nothing was run' absent "$ROOT/ran"

for id in '../../v1/apps/demo' '0193A5C0-0000-7000-8000-00000000000A' 'x'; do
    anew
    REQUEST_ID=$id waits v3.11.4
    out=$(job -- touch "$ROOT/ran" 2>&1)
    code=$?
    check "a request id that is no uuid ($id): refused in words" has "$out" 'not run: Deploys named a request whose id is not a uuid'
    check 'it ends 1' same "$code" 1
    check 'the id went into no address: one call, to ask' same "$(cat "$ROOT/state/requests")" 'POST /api/v1/job/ask '
    check 'nothing was run' absent "$ROOT/ran"
done

# --- the key is for another app: it stops before anything is run or refused
anew
waits v3.11.4 ',"app":"api"'
out=$(job -- touch "$ROOT/ran" 2>&1)
code=$?
check 'another app'"'"'s key: said in the spec'"'"'s words' same "$out" 'mybeast-deploy: this key is for api in staging, not demo in staging: check --app and --env, or the key'
check 'it ends 2' same "$code" 2
check 'nothing was run' absent "$ROOT/ran"
check 'nothing was refused or started: one call, to ask' same "$(cat "$ROOT/state/requests")" 'POST /api/v1/job/ask '

# --- no report, no run: a start nobody confirms runs nothing, and the next run says so to Deploys
anew
waits v3.11.4
printf 3 >"$ROOT/state/lose-start"
out=$(job -- touch "$ROOT/ran" 2>&1)
code=$?
check 'no answer to the start: said in the spec'"'"'s words' has "$out" "mybeast-deploy: not run: Deploys did not confirm the start ($HERE answered 500: the answer was lost). Nothing changed."
check 'it ends 1' same "$code" 1
check 'it tried three times' same "$(count starts)" 3
check 'nothing was run' absent "$ROOT/ran"
check 'the journal has the request, and that its start was not confirmed' [ -e "$ENTRY/taken" -a -e "$ENTRY/unconfirmed" ]
check 'and no run' absent "$ENTRY/run"
out=$(job -- touch "$ROOT/ran" 2>&1)
code=$?
check 'the next run asks about that start' same "$(count starts)" 4
check 'and still runs nothing' absent "$ROOT/ran"
check 'it finishes the run as stopped' same "$(field "$ROOT/state/finished.json" status)" cancelled
check 'with the one line' same "$(cat "$ROOT/state/log")" 'mybeast-deploy: Deploys did not confirm the start in time, so the script was not run. Nothing changed.'
check 'and says so here' same "$out" 'mybeast-deploy: Rollback #1 was not run. Nothing changed, and Deploys was told.'
check 'it ends 0' same "$code" 0
out=$(job -- touch "$ROOT/ran" 2>&1)
check 'after that nothing is owed, and nothing said' same "$out" ''
check 'the run was finished once' same "$(count finishes)" 1

# --- a start answered 409 is said and dropped
anew
waits v3.11.4
touch "$ROOT/state/start-409"
out=$(job -- touch "$ROOT/ran" 2>&1)
code=$?
check 'a 409 to the start: said' has "$out" "not run: the request is no longer this job's to start ($HERE answered 409: This request is not waiting for this job any more.). Nothing changed."
check 'the stand-in kept no start' same "$(count starts)" 0
check 'nothing was run' absent "$ROOT/ran"
check 'and dropped: the journal keeps nothing of it' absent "$ENTRY"
check 'it ends 0' same "$code" 0

# --- a script that hangs is stopped past --timeout, with all it started; nothing of the job stays behind
anew
waits v3.11.4
set -m
job --timeout 2 -- sh -c 'echo $$ >"$0"; echo hanging; sleep 31.7 & wait' "$ROOT/pid" >"$ROOT/out" 2>"$ROOT/err" &
running=$!
set +m
wait "$running"
code=$?
check 'a hanging script: the job ends with the code of what it stopped' same "$code" 143
check 'finished as failed' same "$(field "$ROOT/state/finished.json" status)" failed
check 'exit code 143' same "$(field "$ROOT/state/finished.json" exit_code)" 143
check 'the last line of the log is the job'"'"'s, and says why' same "$(tail -n 1 "$ROOT/state/log")" 'mybeast-deploy: stopped after 2 s (--timeout): the script was still running.'
check 'after the script'"'"'s own words' same "$(head -n 1 "$ROOT/state/log")" hanging
check 'the script is gone' gone "$(cat "$ROOT/pid")"
check 'and what it started' gone "-$(cat "$ROOT/pid")"
check 'the watchdog is gone, and the rest of the job' gone "-$running"

# --- told to stop (TERM), the job stops the script and reports it as stopped
anew
waits v3.11.4
set -m
job -- sh -c 'echo $$ >"$0"; echo waiting; sleep 31.8 & wait' "$ROOT/pid" >/dev/null 2>&1 &
running=$!
set +m
until_there "$ROOT/pid" && until_there "$JOB/lock/pid"
kill -TERM "$(cat "$JOB/lock/pid")"
wait "$running"
check 'told to stop: the script is stopped' gone "-$(cat "$ROOT/pid")"
check 'and reported as stopped' same "$(field "$ROOT/state/finished.json" status)" cancelled
check 'with the job'"'"'s word in the log' same "$(tail -n 1 "$ROOT/state/log")" 'mybeast-deploy: the job was told to stop, and stopped the script.'
check 'nothing of the job stays behind' gone "-$running"

# --- the same when the signal takes the job's helpers with it (its whole process group is told to stop)
anew
waits v3.11.4
set -m
job -- sh -c 'echo $$ >"$0"; echo waiting; sleep 31.6 & wait' "$ROOT/pid" >/dev/null 2>&1 &
running=$!
set +m
until_there "$ROOT/pid" && until_there "$JOB/lock/pid"
kill -TERM -- "-$running"
wait "$running" 2>/dev/null
until_there "$ROOT/state/finished.json"
check 'the whole job told to stop: the script is stopped all the same' gone "-$(cat "$ROOT/pid")"
check 'and reported as stopped' same "$(field "$ROOT/state/finished.json" status)" cancelled
check 'with the job'"'"'s word in the log' same "$(tail -n 1 "$ROOT/state/log")" 'mybeast-deploy: the job was told to stop, and stopped the script.'
check 'nothing of the job stays behind' gone "-$running"

# --- killed outright, the job leaves no script running; the next run reports the run as cut short
anew
waits v3.11.4
set -m
job -- sh -c 'echo $$ >"$0"; echo "half way"; sleep 31.9 & wait' "$ROOT/pid" >/dev/null 2>&1 &
running=$!
set +m
until_there "$ROOT/pid" && until_there "$JOB/lock/pid" && until_there "$ROOT/state/log"
kill -KILL "$(cat "$JOB/lock/pid")"
wait "$running" 2>/dev/null
check 'the job killed outright: its watch stops the script' gone "-$(cat "$ROOT/pid")"
check 'and then goes itself, with the rest' gone "-$running"
check 'the lock is left behind, with a dead pid' [ -e "$JOB/lock/pid" ]
out=$(job -- touch "$ROOT/ran" 2>&1)
code=$?
check 'the next run takes the lock over and says what happened' same "$out" 'mybeast-deploy: Rollback #1 was cut short: this machine restarted, or the job was stopped. Deploys was told it failed.'
check 'the run is finished as failed' same "$(field "$ROOT/state/finished.json" status)" failed
check 'with no exit code: it is not known' same "$(field "$ROOT/state/finished.json" exit_code)" ''
check 'the log ends with the job'"'"'s line' same "$(cat "$ROOT/state/log")" "$(printf 'half way\nmybeast-deploy: the job was cut short here: this machine restarted, or the job was stopped. How the script ended is not known.')"
check 'nothing was run' absent "$ROOT/ran"
check 'it ends 0' same "$code" 0
check 'the lock is given back' absent "$JOB/lock"

# --- a journal with a run that began and never ended, made by hand: reported as failed, with the line
anew
mkdir -p "$ENTRY"
printf '%s\n' "$(($(date +%s) - 300))" | tee "$ENTRY/taken" >"$ENTRY/began"
printf '%s\n' "$RUN" >"$ENTRY/run"
printf 'Rollback #7\n' >"$ENTRY/title"
printf '%s\n' "$PAGE" >"$ENTRY/url"
printf 'one\ntwo, cut' >"$ENTRY/log"
printf 4 >"$ENTRY/offset"
printf '{}' >"$ROOT/state/job-started.json"
printf 'one\n' >"$ROOT/state/log"
out=$(job -- touch "$ROOT/ran" 2>&1)
code=$?
check 'a run that began and never ended: said in the spec'"'"'s words' same "$out" 'mybeast-deploy: Rollback #7 was cut short: this machine restarted, or the job was stopped. Deploys was told it failed.'
check 'reported as failed' same "$(field "$ROOT/state/finished.json" status)" failed
check 'the rest of its log arrives, then the line' same "$(cat "$ROOT/state/log")" "$(printf 'one\ntwo, cut\nmybeast-deploy: the job was cut short here: this machine restarted, or the job was stopped. How the script ended is not known.')"
check 'nothing was run' absent "$ROOT/ran"
check 'it ends 0, and asked after that' same "$code:$(count asks)" 0:1

# --- a finish that fails once is delivered by the next run
anew
waits v3.11.4
touch "$ROOT/state/fail-finish-once"
out=$(job -- sh -c 'echo rolled; exit 0' 2>&1)
code=$?
check 'a finish not taken: the rollback'"'"'s own code stands' same "$code" 0
check 'and it says who reports it' has "$out" "mybeast-deploy: how it ended was not reported: $HERE answered 500: not kept, for the test - the next run of the job reports it"
check 'the service has no end yet' absent "$ROOT/state/finished.json"
out=$(job -- touch "$ROOT/ran" 2>&1)
check 'the next run delivers it' same "$(field "$ROOT/state/finished.json" status):$(field "$ROOT/state/finished.json" exit_code)" succeeded:0
check 'and says so' same "$out" "mybeast-deploy: Rollback #1 succeeded in 3s, release v3.11.4: $PAGE"
check 'the script is not run again' absent "$ROOT/ran"

# --- the service down while the script runs: it finishes, and the next run delivers the rest of the log and the end
anew
waits v3.11.4
out=$(job -- sh -c 'echo one; i=0; while [ ! -s "$0/log" ] && [ $i -lt 100 ]; do i=$((i + 1)); sleep 0.1; done; touch "$0/down"; echo two; exit 4' "$ROOT/state" 2>"$ROOT/err")
code=$?
check 'the service down during the run: the script finishes with its own code' same "$code" 4
check 'its output is all on the terminal' same "$out" "$(printf 'one\ntwo')"
check 'the service has the first part' same "$(cat "$ROOT/state/log")" one
check 'the job says what waits' has "$(cat "$ROOT/err")" "mybeast-deploy: the log did not all reach Deploys ($HERE answered 503: down for the test): the next run of the job sends the rest, and how it ended"
out=$(job -- touch "$ROOT/ran" 2>&1)
check 'while it is down the next run says so, once an hour, and ends 1' same "$out:$?" "mybeast-deploy: $HERE answered 503: down for the test (said once an hour):1"
check 'what is owed comes before anything new: it did not ask' same "$(tail -n 1 "$ROOT/state/requests")" "POST /api/v1/job/deploys/$RUN/lines offset=4"
rm "$ROOT/state/down"
out=$(job -- touch "$ROOT/ran" 2>&1)
check 'the next run sends the rest of the log' same "$(cat "$ROOT/state/log")" "$(printf 'one\ntwo')"
check 'and the end as it was' same "$(field "$ROOT/state/finished.json" status):$(field "$ROOT/state/finished.json" exit_code)" failed:4
check 'and says so' same "$out" "mybeast-deploy: Rollback #1 failed in 3s, release v3.11.4: $PAGE"
check 'nothing was run again' absent "$ROOT/ran"

# --- a run that has its end at the service already (the answer was lost): its log is not offered for ever
anew
mkdir -p "$ENTRY"
date +%s | tee "$ENTRY/taken" >"$ENTRY/began"
printf '%s\n' "$RUN" >"$ENTRY/run"
printf 'Rollback #7\n' >"$ENTRY/title"
printf '%s\n' "$PAGE" >"$ENTRY/url"
printf 'succeeded 0 5\n' >"$ENTRY/ended"
printf 'one\ntwo\n' >"$ENTRY/log"
printf 4 >"$ENTRY/offset"
printf '{}' >"$ROOT/state/job-started.json"
printf 'one\n' >"$ROOT/state/log"
printf '{"status":"succeeded","exit_code":"0"}' >"$ROOT/state/finished.json"
out=$(job -- touch "$ROOT/ran" 2>&1)
check 'an end the service has already: taken as told' same "$out:$?" "mybeast-deploy: Rollback #7 succeeded in 3s: $PAGE:0"
check 'the log it no longer takes was offered once' same "$(count batches):$(grep -c /lines "$ROOT/state/requests")" 0:1
check 'and the request is closed' [ -e "$ENTRY/closed" ]

# --- a script that leaves something running does not hold the job: its end is the script's own end
anew
waits v3.11.4
set -m
job -- sh -c 'sleep 21.3 & echo $! >"$0"; echo "worker started"' "$ROOT/pid" >"$ROOT/out" 2>/dev/null &
running=$!
set +m
wait "$running"
code=$?
check 'a script that leaves a worker behind: the job ends with the script' same "$code:$(cat "$ROOT/out")" '0:worker started'
check 'reported as succeeded' same "$(field "$ROOT/state/finished.json" status)" succeeded
check 'the worker is left alone' kill -0 "$(cat "$ROOT/pid")"
kill "$(cat "$ROOT/pid")" 2>/dev/null
check 'nothing of the job stays behind' gone "-$running"

# --- two runs at once: the second leaves without a word; a lock left behind is taken over
anew
waits v3.11.4
job -- sh -c 'sleep 1.5; echo slow' >/dev/null 2>&1 &
running=$!
until_there "$ROOT/state/job-started.json"
out=$(job -- touch "$ROOT/ran" 2>&1)
code=$?
wait "$running"
check 'a second run while the first is at work: it ends 0' same "$code" 0
check 'and says nothing' same "$out" ''
check 'and asked nothing' same "$(count asks)" 1
check 'and ran nothing' absent "$ROOT/ran"
check 'the first went on to its end' same "$(field "$ROOT/state/finished.json" status)" succeeded

anew
mkdir -p "$JOB/lock"
sh -c 'exit 0' &
wait $!
printf '%s\n' "$!" >"$JOB/lock/pid"
out=$(job -- touch "$ROOT/ran" 2>&1)
check 'a lock whose run is gone is taken over' same "$(count asks):$out" 1:
check 'and given back' absent "$JOB/lock"

anew
mkdir -p "$JOB/lock"
out=$(job -- touch "$ROOT/ran" 2>&1)
check 'a lock left with no pid in it is taken over too, after a few looks' same "$(count asks):$out" 1:
check 'and given back' absent "$JOB/lock"

# --- a test from the page: what it would run, said here and to Deploys; nothing runs
anew
waits v3.11.4 ',"test":true'
out=$(job -- touch "$ROOT/ran" 2>&1)
code=$?
check 'a test: said in the spec'"'"'s words' same "$out" "mybeast-deploy: took a test from the page. It would run: RELEASE=v3.11.4 touch $ROOT/ran. Nothing was run."
check 'Deploys is told the command' same "$(field "$ROOT/state/tested.json" command)" "touch $ROOT/ran"
check 'nothing was run' absent "$ROOT/ran"
check 'nothing was started' same "$(count starts)" 0
check 'it ends 0' same "$code" 0

anew
waits v3.11.4 ',"test":true'
out=$(job -- "$ROOT/no-such-script" 2>&1)
check 'a test finds a command that is not there' has "$out" "not run: the job's own command was not found on this machine: $ROOT/no-such-script. Deploys was told."
check 'and Deploys hears it' same "$(field "$ROOT/state/refused.json" why)" "the job's own command was not found on this server"

# --- at most 6 runs begin in an hour, by the journal
anew
waits v3.11.4
for n in 1 2 3 4 5 6; do
    mkdir -p "$JOB/journal/0193a5c0-0000-7000-8000-00000000000$n"
    date +%s | tee "$JOB/journal/0193a5c0-0000-7000-8000-00000000000$n/began" "$JOB/journal/0193a5c0-0000-7000-8000-00000000000$n/taken" >"$JOB/journal/0193a5c0-0000-7000-8000-00000000000$n/closed"
done
out=$(job -- touch "$ROOT/ran" 2>&1)
check 'a seventh in the hour is refused' same "$out" 'mybeast-deploy: not run: 6 rollbacks began here in the last hour, the most the job runs. Deploys was told.'
check 'and not run' absent "$ROOT/ran"
anew
waits v3.11.4
for n in 1 2 3 4 5 6; do
    mkdir -p "$JOB/journal/0193a5c0-0000-7000-8000-00000000000$n"
    date +%s | tee "$JOB/journal/0193a5c0-0000-7000-8000-00000000000$n/began" "$JOB/journal/0193a5c0-0000-7000-8000-00000000000$n/taken" >"$JOB/journal/0193a5c0-0000-7000-8000-00000000000$n/closed"
done
printf '%s\n' "$(($(date +%s) - 3601))" >"$JOB/journal/0193a5c0-0000-7000-8000-000000000001/began"
job -- touch "$ROOT/ran" >/dev/null 2>&1
check 'one that began over an hour ago does not count' [ -e "$ROOT/ran" ]

# --- the journal keeps the last 20 closed requests
anew
for n in 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34; do
    mkdir -p "$JOB/journal/0193a5c0-0000-7000-8000-0000000000$n"
    printf '%s\n' "$(($(date +%s) - 7200 - n))" | tee "$JOB/journal/0193a5c0-0000-7000-8000-0000000000$n/taken" >"$JOB/journal/0193a5c0-0000-7000-8000-0000000000$n/closed"
done
job -- touch "$ROOT/ran" >/dev/null 2>&1
check 'of 25 closed requests the last 20 stay' same "$(ls "$JOB/journal" | wc -l | tr -d ' ')" 20
check 'the newest among them' [ -e "$JOB/journal/0193a5c0-0000-7000-8000-000000000010" ]
check 'the oldest gone' absent "$JOB/journal/0193a5c0-0000-7000-8000-000000000034"

# --- a refused key is said once an hour, not every minute; the service down or out of reach: the same
anew
out=$(JOB_KEY='jk_wrong.wrong' job -- touch "$ROOT/ran" 2>&1)
code=$?
check 'a refused key: said' same "$out" "mybeast-deploy: the key was refused: revoked, mistyped, or not a key of $HERE (said once an hour)"
check 'it ends 1' same "$code" 1
out=$(JOB_KEY='jk_wrong.wrong' job -- touch "$ROOT/ran" 2>&1)
code=$?
check 'the minute after: not said again' same "$out" ''
check 'it still ends 1' same "$code" 1
printf '%s\n' "$(($(date +%s) - 3601))" >"$JOB/said"
out=$(JOB_KEY='jk_wrong.wrong' job -- touch "$ROOT/ran" 2>&1)
check 'an hour later: said again' has "$out" 'the key was refused'
check 'nothing was run' absent "$ROOT/ran"

anew
touch "$ROOT/state/down"
out=$(job -- touch "$ROOT/ran" 2>&1)
code=$?
check 'the service down: said' same "$out" "mybeast-deploy: $HERE answered 503: down for the test (said once an hour)"
check 'it ends 1' same "$code" 1
out=$(job -- touch "$ROOT/ran" 2>&1)
check 'the minute after: not said again' same "$out:$?" ':1'

anew
out=$(JOB_URL='http://127.0.0.1:1' job -- touch "$ROOT/ran" 2>&1)
check 'the service out of reach: said in the spec'"'"'s words' same "$out:$?" 'mybeast-deploy: could not reach http://127.0.0.1:1 (said once an hour):1'
out=$(JOB_URL='http://127.0.0.1:1' job -- touch "$ROOT/ran" 2>&1)
check 'the minute after: not said again' same "$out:$?" ':1'

# --- each key does its own work only: refused in words, before anything is sent
anew
out=$(JOB_KEY="$KEY" job -- touch "$ROOT/ran" 2>&1)
code=$?
check 'a server key given to job: said in the spec'"'"'s words' same "$out" "mybeast-deploy: MYBEAST_DEPLOYS_JOB_KEY holds a server key (sk_…): the job needs a job key (jk_…), made on the app's Settings, Rolling back"
check 'it ends 2' same "$code" 2
for mode in run rollback status; do
    out=$(env -u MYBEAST_DEPLOYS_JOB_KEY HOME="$ROOT/home" MYBEAST_DEPLOYS_CONFIG="$ROOT/none" MYBEAST_DEPLOYS_URL="$HERE" MYBEAST_DEPLOYS_KEY="$JOB_KEY" \
        "$CLI" "$mode" --app demo --env staging -- touch "$ROOT/ran" 2>&1)
    code=$?
    check "a job key given to $mode: refused in words" has "$out" "mybeast-deploy: MYBEAST_DEPLOYS_KEY holds a job key (jk_…): $mode needs a server key (sk_…)"
    check 'it ends 2' same "$code" 2
done
check 'nothing was sent' absent "$ROOT/state/requests"
check 'nothing was run' absent "$ROOT/ran"

# --- what the job cannot do without is said, with 2
anew
out=$(cron job --app demo --env staging -- touch "$ROOT/ran" 2>&1)
check 'no list of releases: said in the spec'"'"'s words' same "$out:$?" "mybeast-deploy: job needs --releases-dir DIR or --releases-from 'COMMAND': it only rolls back to a release it can see:2"
out=$(job --releases-from 'ls' -- touch "$ROOT/ran" 2>&1)
check 'both lists: refused' same "$out:$?" 'mybeast-deploy: job takes --releases-dir or --releases-from, not both: one list of the releases it can see:2'
out=$(job 2>&1)
check 'no command: said in the spec'"'"'s words' same "$out:$?" 'mybeast-deploy: job needs its command after --: it never takes one from the service:2'
out=$(job -- 2>&1)
check 'nothing after --: the same' same "$out:$?" 'mybeast-deploy: job needs its command after --: it never takes one from the service:2'
out=$(job --to v3.11.4 -- touch "$ROOT/ran" 2>&1)
check 'the job names no release itself' same "$out:$?" 'mybeast-deploy: job does not take --to (see mybeast-deploy --help):2'
out=$(deploy run --app demo --env staging --check -- touch "$ROOT/ran" 2>&1)
check 'run does not take the job'"'"'s options' same "$out:$?" 'mybeast-deploy: run does not take --check (see mybeast-deploy --help):2'
out=$(cron job --app demo --env staging --releases-dir "$ROOT/no-such-folder" -- touch "$ROOT/ran" 2>&1)
check 'a releases folder that is not there' same "$out:$?" "mybeast-deploy: the releases could not be read: $ROOT/no-such-folder is not a folder on this machine (said once an hour):2"
check 'none of these sent anything' absent "$ROOT/state/requests"
check 'nor ran anything' absent "$ROOT/ran"

# --- --releases-from: the lines a command of the machine's own prints, read without a key
anew
out=$(SERVER_KEY="$KEY" cron job --app demo --env staging --releases-from 'if env | grep _KEY=; then exit 9; fi; printf "v2\nv1\n../x\nwith space\n\nv3"' -- touch "$ROOT/ran" 2>&1)
check 'the lines of --releases-from, names of a job'"'"'s shape only, read without a key' same "$(field "$ROOT/state/asked.json" releases):$out" "$(printf 'v3\nv2\nv1'):"
out=$(cron job --app demo --env staging --releases-from 'echo v1; echo "no such host" >&2; exit 5' -- touch "$ROOT/ran" 2>&1)
check 'a list that cannot be read stops the job' same "$out:$?" "mybeast-deploy: the releases could not be read: 'echo v1; echo \"no such host\" >&2; exit 5' ended with 5: no such host (said once an hour):2"
out=$(cron job --app demo --env staging --releases-from 'exit 5' -- touch "$ROOT/ran" 2>&1)
check 'and is not said again the minute after' same "$out:$?" ':2'

# --- two jobs whose names come to the same folder do not share it
anew
cron job --app a-b --env c --releases-dir "$ROOT/releases" -- true >/dev/null 2>&1
out=$(cron job --app a --env b-c --releases-dir "$ROOT/releases" -- true 2>&1)
check 'a folder that is another job'"'"'s is not shared' same "$out:$?" "mybeast-deploy: $ROOT/job/a-b-c is the folder of the job for a-b in c: MYBEAST_DEPLOYS_STATE names another place for this one:2"

# --- --check: the block, a pulse that takes nothing
anew
waits v3.11.4
out=$(job --check -- touch "$ROOT/ran" 2>&1)
code=$?
check '--check prints the block' same "$out" "mybeast-deploy: checking the job for demo in staging. Nothing will be run.
  key        ok: it is for demo in staging (demo.test)
  releases   3 in $ROOT/releases: v3.12.1 v3.11.4 v3.11.3
  command    touch $ROOT/ran (it gets RELEASE=<one of the releases>)
  the page   on: http://deploys.test/projects/p/apps/demo/settings/rollback/staging
mybeast-deploy: Deploys heard this machine as $(hostname -s 2>/dev/null || uname -n)."
check 'it ends 0' same "$code" 0
check 'the call says it is a check' same "$(field "$ROOT/state/asked.json" check)" 1
check 'and names the releases' same "$(field "$ROOT/state/asked.json" releases)" "$(printf 'v3.12.1\nv3.11.4\nv3.11.3')"
check 'the request that waits is not taken: one call' same "$(cat "$ROOT/state/requests")" 'POST /api/v1/job/ask '
check 'nothing was run' absent "$ROOT/ran"
check 'it takes no lock' absent "$JOB/lock"
mkdir "$JOB/lock"
sleep 20 &
printf '%s\n' "$!" >"$JOB/lock/pid"
out=$(job --check -- touch "$ROOT/ran" 2>&1)
check 'and works beside a run that holds it' has "$out:$?" 'Deploys heard this machine as'
kill "$!" 2>/dev/null
wait "$!" 2>/dev/null

anew
printf '{"on":false}' >"$ROOT/state/request.json"
out=$(job --check -- touch "$ROOT/ran" 2>&1)
check 'the page off: said, and nothing wrong' has "$out:$?" "  the page   off: an admin switches it on at http://deploys.test/projects/p/apps/demo/settings/rollback/staging
mybeast-deploy: Deploys heard this machine as $(hostname -s 2>/dev/null || uname -n).:0"

anew
printf '{"app":"api","environment":"production"}' >"$ROOT/state/request.json"
out=$(job --check -- touch "$ROOT/ran" 2>&1)
code=$?
check '--check with another app'"'"'s key: said' has "$out" '  key        this key is for api in production, not demo in staging: check --app and --env, or the key'
check 'it ends 2' same "$code" 2

anew
out=$(cron job --app demo --env staging --releases-dir "$ROOT/empty" --check -- touch "$ROOT/ran" 2>&1)
code=$?
check '--check with no release found: said' has "$out" "  releases   none in $ROOT/empty: the job only rolls back to a release it can see"
check 'it ends 2' same "$code" 2

anew
touch "$ROOT/state/down"
out=$(job --check -- touch "$ROOT/ran" 2>&1)
code=$?
check '--check with the service down: said' has "$out" "  key        not checked: $HERE answered 503: down for the test"
check 'it ends 2' same "$code" 2
out=$(job --check -- touch "$ROOT/ran" 2>&1)
check 'and said every time: a person asked' has "$out" 'not checked'

anew
out=$(job --check -- "$ROOT/no-such-script" 2>&1)
code=$?
check '--check with a command that is not there: said' has "$out" "  command    not found on this machine: $ROOT/no-such-script"
check 'it ends 2' same "$code" 2

# --- the job's key from the config file, which must be private
anew
printf 'MYBEAST_DEPLOYS_URL=%s\nMYBEAST_DEPLOYS_KEY="%s"\nMYBEAST_DEPLOYS_JOB_KEY=%s\n' "$HERE" "$KEY" "$JOB_KEY" >"$ROOT/home/.config/mybeast/deploys.env"
chmod 644 "$ROOT/home/.config/mybeast/deploys.env"
out=$(env -u MYBEAST_DEPLOYS_URL -u MYBEAST_DEPLOYS_KEY -u MYBEAST_DEPLOYS_JOB_KEY -u MYBEAST_DEPLOYS_CONFIG HOME="$ROOT/home" XDG_CONFIG_HOME= MYBEAST_DEPLOYS_STATE="$ROOT/job" \
    "$CLI" job --app demo --env staging --releases-dir "$ROOT/releases" -- touch "$ROOT/ran" 2>&1)
check 'the job: a file others can read is refused' has "$out" 'can be read by others'
chmod 600 "$ROOT/home/.config/mybeast/deploys.env"
out=$(env -u MYBEAST_DEPLOYS_URL -u MYBEAST_DEPLOYS_KEY -u MYBEAST_DEPLOYS_JOB_KEY -u MYBEAST_DEPLOYS_CONFIG HOME="$ROOT/home" XDG_CONFIG_HOME= MYBEAST_DEPLOYS_STATE="$ROOT/job" \
    "$CLI" job --app demo --env staging --releases-dir "$ROOT/releases" -- touch "$ROOT/ran" 2>&1)
check 'the job'"'"'s key comes from the file, beside the server key' same "$(count asks):$out" 1:

printf '%s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" = 0 ]
