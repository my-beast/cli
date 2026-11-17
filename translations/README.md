# mybeast-translations

An app's own words in and out of its repo, with [My Beast Translations](https://services.my-beast.com/translations):
the language files go to the service as they are, people review the words there, and the reviewed words come back
into the files. Bash and curl, nothing else (gzip is used when it is there); bash 3.2 (macOS) and up.

For JSON files: i18next's (nested or flat, with its plural keys), plain JSON, and Laravel's `lang/{lang}.json`.
Laravel's PHP files are read by the app itself: `composer require mybeast/translations-laravel`.

## Settings

A file in the repo's root, `.mybeast-translations`, names the source language and the files, with `{lang}` where the
language goes:

```
source en
file resources/js/locales/{lang}.json i18next
file lang/{lang}.json laravel-json
```

And where the service is, from the environment or from `~/.config/mybeast/translations.env` (readable by its owner
only):

```bash
export MYBEAST_TRANSLATIONS_URL=https://services.my-beast.com/translations
export MYBEAST_TRANSLATIONS_SECRET=sk_….…   # a server key: the project's Settings → Keys, or the one in Secrets
```

The secret goes to curl on its standard input, never on its command line.

## Use

```bash
mybeast-translations push            # sends every language file there is; new keys are added and translated
mybeast-translations push --prune    # the main branch's push: keys the files no longer have are archived
mybeast-translations pull            # writes the other languages' files: the words that are served
mybeast-translations check           # changes nothing; ends 1 when a language misses keys or a text fails a check
mybeast-translations status          # how the project's strings stand
```

- **push** sends each file as it is; the service reads the format. What the repo has in another language comes in as
  the machine's words and goes through the checks; it never goes over words a person reviewed - there it waits beside
  them as a proposal. The first push may say the repo's other languages are reviewed already: `--existing reviewed`.
  A key the files no longer have is archived only with `--prune`, so a feature branch's push never removes one. What
  is missing in a language is translated by the machine: a few at once, many in the background. `--wait` waits for
  it (10 minutes, or `--wait=SECONDS`).
- **pull** writes every file in each of the project's other languages, the way the source file is written - its
  order, its nesting, its indent. It holds the reviewed words, and the machine's where the language uses them at
  once; a key with nothing to serve is left out, so the app falls back to its source language there. Each file is
  written beside its place and moved there whole. The source language's file is never touched, and a file the
  service has no words for yet is left as it is: no empty file is made, and words that are here are never replaced
  by none. In a deploy, a failed pull changes nothing: the files in the repo are used.
- **check** is for CI. Words a person approved as they are pass, so a difference that is on purpose is accepted once.
- A language the repo spells its own way (`pt_BR.json`) keeps its file's name; the service calls it `pt-BR`.

It ends with 0, 1 (a check found something), 2 (its own refusals: a bad option, no settings, no file) or 3 (the
service did not take it), and says why in words.

## Tests

```bash
/bin/bash tests/run.sh   # against a stand-in of the API (tests/fake-service.php, php -S)
```

`tests/fixtures` are what the service answers a call that accepts `text/plain`, rendered by services' own
`Controllers\Api\Plain` from `answers.json` (`fixtures/render.php`); `make sdk-check` in the My Beast folder says
when they drift.
