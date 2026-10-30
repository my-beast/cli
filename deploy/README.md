# mybeast-deploy

Runs an app's own deploy script as it is and reports it to MyBeast Deploys (`services.my-beast.com/deploys`): who, from
which machine, the commit, the whole output as it comes, how it ended and how long it took. Bash and curl, nothing else;
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
- `--release NAME` names the build when its log does not (the service finds a `==> Building …` line
  by itself). `rollback --to RELEASE` hands the command `RELEASE=<release>`, which their
  `make rollback` reads.
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

## Try it

`examples/demo-deploy.sh` and `examples/demo-rollback.sh` talk like the real scripts and deploy nothing
(`--fail` makes the deploy fail, `--ask` asks for a "deploy password" first):

```bash
export MYBEAST_DEPLOYS_URL=https://services.my-beast.com/deploys MYBEAST_DEPLOYS_KEY=sk_….…   # a project of your own
./mybeast-deploy run --app demo --env staging -- examples/demo-deploy.sh
./mybeast-deploy run --app demo --env staging -- examples/demo-deploy.sh --fail
./mybeast-deploy rollback --app demo --env staging -- examples/demo-rollback.sh
```

## Tests

```bash
/bin/bash tests/run.sh
```

They run the CLI against `tests/fake-service.php` (a stand-in of the API on `php -S`) in a throwaway git checkout:
what it sends, the log byte for byte, a lost answer resent, batches of at most 256 KB, exit codes, secrets kept back,
`--to`, the app's own command and its yes, the service down, the config file.
