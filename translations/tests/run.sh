#!/usr/bin/env bash
# The CLI's tests: mybeast-translations against a stand-in of the service's strings API (tests/fake-service.php,
# php -S), in a throwaway repo with language files. Its answers are tests/fixtures: what services answers a call that
# accepts text/plain, rendered once by fixtures/render.php - `make sdk-check` in the My Beast folder says when they
# drift. Run it with the bash the CLI must work with: `/bin/bash tests/run.sh` (3.2 on macOS).

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
CLI="$HERE/../mybeast-translations"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/mybeast-translations-tests.XXXXXX")
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
mkdir -p "$ROOT/state" "$ROOT/home"
FAKE_STATE="$ROOT/state" FAKE_FIXTURES="$HERE/fixtures" php -S "127.0.0.1:$PORT" "$HERE/fake-service.php" >"$ROOT/server.log" 2>&1 &
SERVER=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do curl --silent --max-time 1 "http://127.0.0.1:$PORT/" >/dev/null 2>&1 && break; sleep 0.2; done

REPO="$ROOT/repo"

fresh() { # a clean stand-in and a repo as an app has it: English, Finnish, and Brazilian Portuguese spelled its own way
    rm -rf "$ROOT/state" "$REPO" && mkdir -p "$ROOT/state" "$REPO/resources/js/locales" && cd "$REPO" || exit 1
    git init -q -b main . && git config user.name 'Anna Test' && git config user.email 'anna@example.test'
    printf 'source en\n# the front end\nfile resources/js/locales/{lang}.json i18next\n' >.mybeast-translations
    printf '{\n  "common.hello": "Hello {{name}}",\n  "common.save": "Save",\n  "money.title": "Money"\n}\n' >resources/js/locales/en.json
    printf '{\n  "common.hello": "Hei {{name}}"\n}\n' >resources/js/locales/fi.json
    printf '{\n  "common.save": "Salvar"\n}\n' >resources/js/locales/pt_BR.json
    printf 'not a language file\n' >resources/js/locales/README.json
}

cli() { # the CLI as a CI job runs it, with settings in the environment and no config file
    env -u MYBEAST_TRANSLATIONS_KEY -u GITHUB_REF_NAME -u CI_COMMIT_REF_NAME HOME="$ROOT/home" MYBEAST_TRANSLATIONS_CONFIG="$ROOT/none" \
        MYBEAST_TRANSLATIONS_URL="${URL_NOW-http://127.0.0.1:$PORT}" MYBEAST_TRANSLATIONS_SECRET="${KEY_NOW-$KEY}" /bin/bash "$CLI" "$@"
}

sent() { # $1 language → the place of the file sent in that language among sent/
    grep -l "\"language\":\"$1\"" "$ROOT"/state/sent/*.query 2>/dev/null | head -1 | sed 's/\.query$//'
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
absent() { [ ! -e "$1" ]; }

# --- a push: every language file as it is, the branch, then what the service says it did
fresh
out=$(cli push 2>"$ROOT/err")
code=$?
check 'a push ends 0' same "$code" 0
check 'it starts with the branch and no prune' same "$(cat "$ROOT/state/start.json")" '{"prune":false,"existing":"machine","branch":"main"}'
check 'three files went' same "$(ls "$ROOT/state/sent" | grep -c '\.json$')" 3
check 'the English file byte for byte' cmp -s "$(sent en).json" resources/js/locales/en.json
check 'the Finnish file byte for byte' cmp -s "$(sent fi).json" resources/js/locales/fi.json
check 'pt_BR on disk is pt-BR to the service' cmp -s "$(sent pt-BR).json" resources/js/locales/pt_BR.json
check 'each names its file with {lang} and its format' has "$(cat "$(sent fi).query")" '"file":"resources/js/locales/{lang}.json","language":"fi","format":"i18next"'
if command -v gzip >/dev/null 2>&1; then
    check 'sent as gzip when gzip is here' has "$(cat "$(sent en).query")" '"gzip":true'
fi
check 'a file that is no language is not sent' same "$(grep -c README "$ROOT/state/requests")" 0
check 'it accepts plain words' has "$(cat "$ROOT/state/accept")" 'text/plain'
check 'it says how many files went' has "$out" '3 files sent.'
check 'and what the service did' has "$out" 'resources/js/locales/{lang}.json: 3 strings, 1 added, 1 changed'
check 'and for each language' has "$out" 'Swedish (sv): 2 missing - added to the project'
check 'and that the machine goes on' has "$out" 'The machine is writing 2 texts in the background.'
check 'never the line it reads itself' lacks "$out" 'fill 7'
check 'nor the answer'"'"'s first word' lacks "$out" 'pushed'
check 'the secret is on no command line' lacks "$(cat "$ROOT/server.log")" "$KEY"

# --- its options
fresh
cli push --prune --existing reviewed --branch release/1.2 >/dev/null 2>&1
check 'prune, existing and a named branch' same "$(cat "$ROOT/state/start.json")" '{"prune":true,"existing":"reviewed","branch":"release/1.2"}'
fresh
cli push --branch 'odd "name"' >/dev/null 2>&1
check 'a branch that would need escaping is left out' same "$(cat "$ROOT/state/start.json")" '{"prune":false,"existing":"machine"}'
fresh
(cd "$REPO" && git checkout -q -b feature/x && cli push >/dev/null 2>&1)
check 'the branch as git says' has "$(cat "$ROOT/state/start.json")" '"branch":"feature/x"'
check 'a wrong --existing ends 2' same "$(cli push --existing perfect >/dev/null 2>&1; echo $?)" 2
check 'an unknown option ends 2' same "$(cli push --force >/dev/null 2>&1; echo $?)" 2

# --- --wait follows the fill until it is over
fresh
printf 'fill-running\nfill-done\n' >"$ROOT/state/fills"
out=$(cli push --wait=30 2>"$ROOT/err")
check 'a waited push ends 0' same "$?" 0
check 'it asked for the fill until it was done' same "$(grep -c 'GET /api/v1/strings/fills/7' "$ROOT/state/requests")" 2
check 'and says so' has "$out" 'The machine has written what was missing.'
fresh
printf 'fill-waiting\n' >"$ROOT/state/fills"
out=$(cli push --wait 2>/dev/null)
check 'a fill that waits says why' has "$out" 'The machine waits: The Starter package has room for 2,000,000 characters a month, and they are used up.'

# --- a check changes nothing and ends by what it found
fresh
out=$(cli check 2>"$ROOT/err")
check 'a sound check ends 0' same "$?" 0
check 'it is started as a check' same "$(cat "$ROOT/state/start.json")" '{"check":true}'
check 'and says each language is whole' has "$out" 'Finnish (fi): whole and sound'
fresh
printf 'checked-failed\n' >"$ROOT/state/finish"
out=$(cli check 2>"$ROOT/err")
check 'a check that found something ends 1' same "$?" 1
check 'and names the key and what is wrong' has "$out" 'resources/js/locales/fi.json: common.hello - placeholders: missing {{name}}; extra {{nimi}}'
check 'and the missing one' has "$out" 'resources/js/locales/fi.json: money.title - missing'
check 'never its own first word' lacks "$out" 'failed'

# --- a pull writes the other languages, each file whole, the source never
fresh
before=$(cat resources/js/locales/en.json)
out=$(cli pull 2>"$ROOT/err")
check 'a pull ends 0' same "$?" 0
check 'Finnish is written' same "$(cat resources/js/locales/fi.json)" "$(printf '{\n    "common.hello": "Hei {{name}}",\n    "common.save": "Tallenna"\n}')"
check 'a language the repo did not have is written' same "$(cat resources/js/locales/sv.json)" "$(printf '{\n    "common.hello": "Hej {{name}}"\n}')"
check 'the source file is as it was' same "$(cat resources/js/locales/en.json)" "$before"
check 'it says what it wrote' has "$out" 'wrote resources/js/locales/fi.json'
check 'nothing is left beside the files' same "$(ls -a resources/js/locales | grep -c mybeast)" 0
check 'the source language is never asked for' same "$(grep -c 'language=en' "$ROOT/state/requests")" 0

fresh
touch "$ROOT/state/no-files"
out=$(cli pull 2>&1)
check 'a project with no files yet' has "$out" 'the service has no resources/js/locales/{lang}.json yet: push it first'
check 'writes nothing' absent resources/js/locales/sv.json

fresh
touch "$ROOT/state/nothing-served"
before=$(cat resources/js/locales/fi.json)
out=$(cli pull 2>&1)
check 'a file the service has no words for is left as it is' same "$(cat resources/js/locales/fi.json)" "$before"
check 'and it says so' has "$out" 'left resources/js/locales/fi.json as it is: the service has no words to serve for it yet'
check 'no empty file is made for a language that has none' absent resources/js/locales/sv.json
check 'nothing is left beside the files then either' same "$(ls -a resources/js/locales | grep -c mybeast)" 0

# --- how things stand
fresh
out=$(cli status 2>"$ROOT/err")
check 'status ends 0' same "$?" 0
check 'it prints each language' has "$out" 'Swedish (sv), after review: 0 reviewed, 2 machine, 0 outdated, 1 missing, 0 held for a person'
check 'and the fill in words' has "$out" 'The machine: running, 1 of 2 written, 0 held for a person'

# --- the repo's own file
fresh
printf 'source en\nfile lang/{lang}/app.php laravel\n' >.mybeast-translations
check "Laravel's PHP files are the package's" has "$(cli push 2>&1)" 'composer require mybeast/translations-laravel'
printf 'source en\nfile ../other/{lang}.json json\n' >.mybeast-translations
check 'a path outside the repo ends 2' same "$(cli push >/dev/null 2>&1; echo $?)" 2
printf 'source en\nfile locales/en.json json\n' >.mybeast-translations
check 'a file line without {lang}' has "$(cli push 2>&1)" 'needs {lang} once'
printf 'file locales/{lang}.json json\n' >.mybeast-translations
check 'no source line' has "$(cli push 2>&1)" 'has no source line'
printf 'source en\nfile locales/{lang}.json yaml\n' >.mybeast-translations
check 'an unknown format' has "$(cli push 2>&1)" 'the format is i18next, json or laravel-json'
printf 'source en\nfile locales/{lang}.json json\n' >.mybeast-translations
check 'the source file is not here' has "$(cli push 2>&1)" 'locales/en.json is not here'
rm .mybeast-translations
check 'no file at all' has "$(cli push 2>&1)" 'no .mybeast-translations here'
check 'ends 2' same "$(cli check >/dev/null 2>&1; echo $?)" 2
check 'nothing was sent for any of these' absent "$ROOT/state/start.json"

# --- it says plainly what is wrong, and ends 3 when the service did not take it
fresh
printf 'The file is not JSON: syntax error.\n' >"$ROOT/state/refuse-file"
out=$(cli push 2>&1)
check 'a refused file ends 3' same "$?" 3
check 'in the service'"'"'s own words' has "$out" 'was not taken: http://127.0.0.1:'"$PORT"' answered 422: The file is not JSON: syntax error.'
fresh
printf 'The Starter package has room for 2,000 source keys.\n' >"$ROOT/state/refuse-finish"
out=$(cli push 2>&1)
check 'a refused finish ends 3' same "$?" 3
check 'and says nothing changed' has "$out" 'not finished, nothing changed'
check 'with why' has "$out" 'The Starter package has room for 2,000 source keys.'
fresh
check 'a refused secret' has "$(KEY_NOW='sk_other00000000001.secret-secret-secret-secret-secret-secret-123' cli push 2>&1)" 'the secret was refused'
touch "$ROOT/state/down"
check 'the service down ends 3' same "$(cli status >/dev/null 2>&1; echo $?)" 3
rm "$ROOT/state/down"
check 'no answer at all' has "$(URL_NOW='http://127.0.0.1:1' cli status 2>&1)" 'could not reach http://127.0.0.1:1'
check 'no secret' has "$(KEY_NOW='' cli status 2>&1)" 'MYBEAST_TRANSLATIONS_SECRET is not set'
check 'not a server key' has "$(KEY_NOW='st_x.y' cli status 2>&1)" 'does not look like a server key'
check 'plain http elsewhere' has "$(URL_NOW='http://example.com' cli status 2>&1)" 'must be https://'
check 'no command at all shows the usage' has "$(cli 2>&1)" 'mybeast-translations push'
check '--version' same "$(cli --version)" 'mybeast-translations 1'
check 'an unknown command ends 2' same "$(cli fly >/dev/null 2>&1; echo $?)" 2

printf '%s passed, %s failed\n' "$PASSED" "$FAILED"
[ "$FAILED" = 0 ]
