# Changelog

## Unreleased

- `mybeast-translations` (1), a fourth command: an app's own words in and out of its repo with My Beast
  Translations. `push` sends every language file as it is (i18next's JSON, plain JSON, Laravel's `lang/{lang}.json`;
  as gzip when gzip is there), `pull` writes the other languages back the way the source file is written, `check`
  ends 1 for CI when a language misses keys or a text fails a check, and `status` says how the strings stand. A file
  in the repo, `.mybeast-translations`, names the source language and the files. See `translations/README.md`.

## 0.2.0 - 2026-11-14

- `mybeast-deploy job` (mybeast-deploy 3): the job behind **Roll back** on the Deploys page. Cron runs it every
  minute on the app's own server, with a key of its own (`MYBEAST_DEPLOYS_JOB_KEY`, `jk_…`). It asks Deploys whether
  someone asked to roll back, and then runs your own rollback script with `RELEASE=<a release the server keeps>` and
  reports the run. It never takes a command from the service, runs nothing Deploys was not told is starting, stops a
  script that hangs (`--timeout`), and delivers at its next run what it could not report. `--check` tries the
  settings and runs nothing. See `deploy/README.md`, "The job".
- `mybeast-deploy run`, `rollback` and `status` refuse a job key, in words, as `job` refuses a server key. The
  command they run gets neither key.
- `mybeast-deploy`: a log is not offered for ever to a deploy the service has already closed, and what sends the log
  ends with the run that started it. A control character in what the service answers is never printed.
- `examples/demo-rollback.sh` takes `--fail` and `--hang`; `examples/releases` is a folder of made-up releases for a
  local job.

## 0.1.0 - 2026-11-01

The first release.
