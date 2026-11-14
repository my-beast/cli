# mybeast-deploy

Runs an app's own deploy script as it is and reports it to My Beast Deploys (`services.my-beast.com/deploys`): who, from
which machine, the commit, the whole output as it comes, how it ended and how long it took. On the app's server it is
also the job that rolls back when someone asks on the Deploys page ("The job", below). Bash and curl, nothing else;
bash 3.2 (macOS's own) and up.

```bash
curl -fsSLo ~/.local/bin/mybeast-deploy https://github.com/my-beast/cli/releases/latest/download/mybeast-deploy
chmod +x ~/.local/bin/mybeast-deploy   # anywhere on your PATH; checking the download: ../README.md
```

## Settings

`MYBEAST_DEPLOYS_URL` (`https://services.my-beast.com/deploys`) and
`MYBEAST_DEPLOYS_KEY` (a server key: the project's Settings → Server keys, shown once; or the one id put in Secrets),
exported or in `~/.config/mybeast/deploys.env` (`MYBEAST_DEPLOYS_CONFIG` names another file). The file is read, never
sourced, and refused when others can read it (`chmod 600`). The key goes to curl on its standard input, never on its
command line, and never to the command it runs.

The job has a key of its own, `MYBEAST_DEPLOYS_JOB_KEY` (a job key, `jk_…`), in the same places. Neither key does
the other's work: `job` refuses a server key, and `run`, `rollback` and `status` refuse a job key.

## Use

From the app's folder (its git checkout says the commit):

```bash
mybeast-deploy run --app shop --env staging -- make deploy:staging
mybeast-deploy run --app my-beast --env production -- make deploy
mybeast-deploy rollback --app shop --env staging -- make rollback:staging
mybeast-deploy rollback --app shop --env staging --to 20261026-101010-abc1234 -- make rollback:staging
mybeast-deploy status --app shop --env staging
```

- **Without a command** (no `--`), it reads the app's own deploy or rollback command from the service (the app's
  Settings page), shows it and asks before it runs it; `--yes` answers for a run without a terminal.
- `--release NAME` names the build. Without it the service takes the name from the first line of the log that the
  app's **release pattern** matches (an admin sets one on the app's Settings page, for example
  `==> Building (\S+)`; an app has none until then), else the commit's first 12 characters.
  `rollback --to RELEASE` hands the command `RELEASE=<release>`, which their `make rollback` reads.
- A deploy sends the checkout's **last 50 commits** (hash, author, subject; from version 2): the service keeps the
  ones since what is live there, so the deploy's page says what it brings. A rollback sends none.
- The command **keeps the terminal**: its prompts (the deploy password, "type production", "type fresh") work as
  without the wrapper, and what is typed there never reaches the service. Its output goes to the terminal at once and
  to the service every 2 s (colours and all; the service shows it plain). A batch whose answer is lost is sent again
  and kept once.
- **Ctrl-C** goes to the command, as always: its own clean-up runs, and the deploy is reported as stopped.
- **The service down** never stops a deploy: it runs unreported (or reported in part), and mybeast-deploy says so; a
  log that did not all arrive is kept in `$TMPDIR/mybeast-deploy-<id>.log`. A deploy whose end was never reported is
  marked lost after 10 minutes.
- It ends with the command's own exit code (2 for its own refusals). The command gets `MYBEAST_DEPLOY_ID` and
  `MYBEAST_DEPLOY_PAGE` (the deploy's page), never `MYBEAST_DEPLOYS_KEY`. A secret-looking value on the command line
  (`DEPLOY_PASSWORD=…`, `--token=…`) is not sent.

## The job

The Deploys page has a **Roll back** button. Deploys never logs in to your server and holds no key to it. A job on
the server asks Deploys every minute whether someone asked to roll back, and when someone did, it runs your own
rollback script. `mybeast-deploy job` is that job (from version 3). One run asks once, so cron runs it every minute:

```bash
* * * * * $HOME/.local/bin/mybeast-deploy job --app web --env production --releases-dir $HOME/web/releases -- $HOME/bin/rollback-web
```

Its settings, in `~/.config/mybeast/deploys.env` (`chmod 600`):

```bash
MYBEAST_DEPLOYS_URL=https://services.my-beast.com/deploys
MYBEAST_DEPLOYS_JOB_KEY=jk_….…   # the app's Settings, Rolling back: for one app in one environment, shown once
```

**Your script** is the command after `--`. The job needs one, and never takes one from the service.

- It gets `RELEASE`: the name of a release this server keeps. That is a folder of `--releases-dir`, or with
  `--releases-from 'COMMAND'` a line of what that command prints. The job reads the list anew at every run, tells
  Deploys the last 50 by name, and runs a release only when it has just seen it in that list.
- Name the releases here as Deploys shows them (see `--release` above): the page offers a release only when the
  job keeps it and Deploys saw a deploy of that name go live in this environment.
- When the script's log names another release than the one it was given (a line the app's release pattern
  matches), Deploys shows the one the log names, and the rollback's page says it is not the one asked for.
- A release's name is 1-64 letters, digits and `. _ + -`, and starts with a letter or a digit. Other folders are
  not releases to the job.
- It runs with no terminal and nothing to read, so it cannot ask anything.
- It ends with 0 only when the app runs on that release. Any other exit code is reported as a failed rollback.
- It has `--timeout` seconds (1800 unless said). Past that the job stops it with everything it started (TERM, then
  KILL 10 s later), and the rollback is reported as failed. When the job itself is stopped or killed, the script is
  stopped with it.
- What it leaves running (a worker, a server) must not keep the script's output open: start it with
  `>/dev/null 2>&1`, as under any cron job.
- It also gets `MYBEAST_DEPLOY_ID`, `MYBEAST_DEPLOY_PAGE` (the rollback's page) and `MYBEAST_ROLLBACK_REQUEST`.
  It never gets a key.

**Try it first.** `--check` runs nothing: it reads the settings and the releases, asks Deploys what the key is for,
and says what it found. It ends with 2 when something is wrong.

```
$ mybeast-deploy job --app web --env production --releases-dir ~/web/releases --check -- ~/bin/rollback-web
mybeast-deploy: checking the job for web in production. Nothing will be run.
  key        ok: it is for web in production (qplet.com)
  releases   5 in /home/qplet/web/releases: v3.12.1 v3.11.4 v3.11.3 v3.11.2 v3.11.1
  command    /home/qplet/bin/rollback-web (it gets RELEASE=<one of the releases>)
  the page   off: an admin switches it on at https://services.my-beast.com/…
mybeast-deploy: Deploys heard this machine as web-1.
```

**What a run does.**

- **Nothing waits:** no output, exit code 0. Cron's log stays empty.
- **A rollback was asked for:** it says whose request it took, tells Deploys the run starts, runs the script, sends
  its output every 2 s and reports how it ended. It ends with the script's own exit code. The script's output also
  goes to the job's own output, so cron mails it or your `>>` keeps it.
- **A test from the page** ("Send a test"): it says what it would run, tells Deploys, and runs nothing.
- **It will not run it:** the release is not kept here any more, the command is not there, 6 rollbacks began in the
  last hour. It says why, here and to Deploys, which shows it on the page.
- **Deploys cannot be reached, or the key is refused:** exit code 1. It says so once an hour, not every minute.
- **Another run is still at work** (a rollback takes longer than a minute): it leaves at once, with 0 and no output.

**What it never does.**

- It never takes a command, a path or an option from the service: only a request's id and a release's name.
- It never runs a release it does not see on this server.
- It never runs what Deploys was not told is starting. No answer to the start: the script does not run, the job
  says so, and the next run tells Deploys it was not run. It does not run it late.
- It never runs the same request twice, two scripts at once, or more than 6 an hour
  (`MYBEAST_DEPLOY_JOB_MAX_PER_HOUR`).
- It never hands the script a key.

**What it keeps.** A folder of its own, for its owner only: `~/.local/state/mybeast/deploy-job/<app>-<env>/`
(`XDG_STATE_HOME` moves it as usual; `MYBEAST_DEPLOYS_STATE` names another folder to put `<app>-<env>` in). In it:
the lock (one run at a time), and a journal with the last 20 requests. What a run could not report is in the
journal, and the next run delivers it before it asks for anything new: the rest of a log and how the rollback ended
when Deploys was down, a rollback cut short by a restart (reported as failed), a start nobody confirmed.

## Try it

`examples/demo-deploy.sh` and `examples/demo-rollback.sh` talk like the real scripts and deploy nothing
(`--fail` makes the deploy fail, `--ask` asks for a "deploy password" first):

```bash
export MYBEAST_DEPLOYS_URL=https://services.my-beast.com/deploys MYBEAST_DEPLOYS_KEY=sk_….…   # a project of your own
./mybeast-deploy run --app demo --env staging -- examples/demo-deploy.sh
./mybeast-deploy run --app demo --env staging -- examples/demo-deploy.sh --fail
./mybeast-deploy rollback --app demo --env staging -- examples/demo-rollback.sh
```

The job, with the made-up releases of `examples/releases` (`demo-rollback.sh --fail` fails, `--hang` never ends, for
`--timeout`):

```bash
export MYBEAST_DEPLOYS_URL=https://services.my-beast.com/deploys MYBEAST_DEPLOYS_JOB_KEY=jk_….…
./mybeast-deploy job --app demo --env staging --releases-dir examples/releases --check -- examples/demo-rollback.sh
./mybeast-deploy job --app demo --env staging --releases-dir examples/releases -- examples/demo-rollback.sh
```

Or with no project at all, against the tests' stand-in of the service (it needs php). Its job key is the one below,
and a request waits while `request.json` is in its folder:

```bash
mkdir -p /tmp/deploys-stand-in && FAKE_STATE=/tmp/deploys-stand-in php -S 127.0.0.1:8099 tests/fake-service.php &
echo '{"request":"0193a5c0-0000-7000-8000-000000000001","release":"20261101-090000-a1b2c3d","asked_by":"Ruis"}' >/tmp/deploys-stand-in/request.json
export MYBEAST_DEPLOYS_URL=http://127.0.0.1:8099 MYBEAST_DEPLOYS_JOB_KEY=jk_testkey000000001.secret-secret-secret-secret-secret-secret-123
./mybeast-deploy job --app demo --env staging --releases-dir examples/releases -- examples/demo-rollback.sh
```

## Tests

```bash
/bin/bash tests/run.sh
```

They run the CLI against `tests/fake-service.php` (a stand-in of the API on `php -S`) in a throwaway git checkout:
what it sends, the log byte for byte, a lost answer resent, batches of at most 256 KB, exit codes, secrets kept back,
`--to`, the app's own command and its yes, the service down, the config file. And the job: the pulse, a request from
its start to its end, each refusal (a release it does not keep, `..`, a leading dash, an id that is no uuid, another
app's key), a start nobody confirms, a script that hangs, the job stopped or killed while the script runs, two runs
at once, what the journal owes, a test request, trouble said once an hour, each key refused where the other belongs,
`--check`.
