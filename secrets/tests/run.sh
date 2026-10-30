#!/usr/bin/env bash
# The CLI's tests: mybeast-secrets as a machine runs it, against a stand-in for curl that answers what the API answers
# (tests/fixtures: services' DotEnv and ShellExport, rendered once - `make sdk-check` in the MyBeast folder says when
# they drift) and writes down how it was called. Run it with the bash the CLI must work with: `/bin/bash tests/run.sh`
# (3.2 on macOS). Needs php for one check: that `run` hands a command every value byte for byte.

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
CLI="$HERE/../mybeast-secrets"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/mybeast-secrets-tests.XXXXXX")
TOKEN='st_abcdefghij012345.Zm9vYmFyYmF6cXV4LXRlc3QtdG9rZW4tc2VjcmV0LXZhbHVl'
PASSED=0 FAILED=0

trap 'rm -rf "$ROOT"' EXIT

mkdir -p "$ROOT/bin" "$ROOT/work"
cat >"$ROOT/bin/curl" <<'BASH'
#!/bin/bash
# Stands in for curl: answers $FAKE/answer-<format> with the status in $FAKE/status.
printf '%s\n' "$@" > "$FAKE/argv"
cat > "$FAKE/config"
out=; url=
while [ $# -gt 0 ]; do
    case $1 in
        --output) out=$2; shift 2 ;;
        --write-out | --header | --proto | --max-time | --config) shift 2 ;;
        -*) shift ;;
        *) url=$1; shift ;;
    esac
done
cp "$FAKE/answer-${url##*format=}" "$out"
cat "$FAKE/status"
BASH
chmod 700 "$ROOT/bin/curl"

fresh() { # the API's answers again, and nothing in the work folder
    cp "$HERE/fixtures/answer-env" "$HERE/fixtures/answer-shell" "$ROOT/"
    printf 200 >"$ROOT/status"
    rm -rf "$ROOT/work" && mkdir -p "$ROOT/work"
}

cli() { # the CLI as a machine runs it: $TOKEN and $URL may be set for one call
    (cd "$ROOT/work" && env -i PATH="$ROOT/bin:/usr/bin:/bin" FAKE="$ROOT" TMPDIR="$ROOT/work" HOME="$ROOT" \
        MYBEAST_SECRETS_URL="${URL:-http://localhost:8012}" MYBEAST_SECRETS_TOKEN="${TOKEN_NOW-$TOKEN}" \
        /bin/bash "$CLI" "$@")
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
absent() { [ ! -e "$1" ] || { printf '    %s is there\n' "$1" >&2; return 1; }; }
mode() { if [ "$(uname)" = Darwin ]; then stat -f %Lp "$1"; else stat -c %a "$1"; fi; }

# --- pull writes the .env whole, for its owner only, and says what it wrote
fresh
cli pull 2>"$ROOT/err"
check 'a pull ends 0' same "$?" 0
check 'the .env is the answer, byte for byte' same "$(cat "$ROOT/work/.env")" "$(cat "$HERE/fixtures/answer-env")"
check 'readable by its owner only' same "$(mode "$ROOT/work/.env")" 600
check 'it says what it wrote' has "$(cat "$ROOT/err")" 'wrote .env (MyBeast Secrets · shop/production · change #7'
check 'the env format was asked for' has "$(cat "$ROOT/argv")" 'http://localhost:8012/api/v1/secrets?format=env'
check 'the token goes on standard input' has "$(cat "$ROOT/config")" "Authorization: Bearer $TOKEN"
check 'never on the command line' lacks "$(cat "$ROOT/argv")" "$TOKEN"

# --- --out FILE, and - for standard output
fresh
mkdir -p "$ROOT/work/config"
cli pull --out config/app.env 2>/dev/null
check '--out FILE' same "$(cat "$ROOT/work/config/app.env")" "$(cat "$HERE/fixtures/answer-env")"
out=$(cli pull --out - 2>/dev/null)
check '--out - prints it' same "$out" "$(cat "$HERE/fixtures/answer-env")"
check 'and leaves no file behind' same "$(ls -A "$ROOT/work" | tr '\n' ' ')" 'config '

# --- a .env it did not write stays, unless --force
fresh
printf 'MINE=1\n' >"$ROOT/work/.env"
cli pull 2>"$ROOT/err"
check 'a hand-made .env refuses' same "$?" 1
check 'and says why' has "$(cat "$ROOT/err")" '.env was not written by mybeast-secrets'
check 'and keeps it' same "$(cat "$ROOT/work/.env")" 'MINE=1'
cli pull --force 2>/dev/null
check '--force overwrites it' same "$(head -1 "$ROOT/work/.env")" "$(head -1 "$HERE/fixtures/answer-env")"
cli pull 2>/dev/null
check 'its own .env is overwritten without --force' same "$?" 0

# --- run hands the command every value exactly, and its exit status comes back
fresh
code='echo json_encode(array_map(fn ($n) => getenv($n), ["APP_NAME", "DB_PASSWORD", "PEM", "UNICODE", "EMPTY", "SEMI"]), JSON_UNESCAPED_UNICODE); exit(3);'
out=$(cli run -- "$(command -v php)" -r "$code" 2>"$ROOT/err")
check 'the command exit status comes back' same "$?" 3
check 'every value, byte for byte' same "$out" "$(cat "$HERE/fixtures/values.json")"
check 'the shell format was asked for' has "$(cat "$ROOT/argv")" 'format=shell'
check 'nothing is left behind' same "$(ls -A "$ROOT/work")" ''

# --- run runs nothing when a line of the answer is not a variable
fresh
printf "export A=\$'1'\ntouch %s/ran\n" "$ROOT/work" >"$ROOT/answer-shell"
cli run -- touch "$ROOT/work/command-ran" 2>"$ROOT/err"
check 'a line that is not a variable ends 1' same "$?" 1
check 'and says nothing was run' has "$(cat "$ROOT/err")" 'not a variable; nothing was run'
check 'the line did not run' absent "$ROOT/work/ran"
check 'nor did the command' absent "$ROOT/work/command-ran"

# --- it says plainly what is wrong
fresh
printf 401 >"$ROOT/status"
check 'a refused token' has "$(cli pull 2>&1)" 'the token was refused'
check 'writes nothing' absent "$ROOT/work/.env"
printf 429 >"$ROOT/status"
check 'too many reads' has "$(cli pull 2>&1)" 'too many reads just now'
printf 200 >"$ROOT/status"
check 'no token' has "$(TOKEN_NOW='' cli pull 2>&1)" 'MYBEAST_SECRETS_TOKEN is not set'
check 'not a service token' has "$(TOKEN_NOW='sk_x.y' cli pull 2>&1)" 'does not look like a service token'
check 'plain http elsewhere' has "$(URL='http://example.com' cli pull 2>&1)" 'must be https://'
check 'run without a command' has "$(cli run -- 2>&1)" 'run needs a command'
check 'no command at all shows the usage' has "$(cli 2>&1)" 'mybeast-secrets pull'
check '--version' same "$(cli --version)" 'mybeast-secrets 1'

printf '%s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" = 0 ]
