# My Beast CLI

Four commands for the machines that build, deploy and run your apps, one bash file each. They need bash 3.2 or newer
(macOS's own) and curl, nothing else, and never put a key on a command line, where other users' `ps` would see it.

| Command | Product | Does |
|---|---|---|
| [`mybeast-deploy`](deploy/README.md) | [Deploys](https://services.my-beast.com/deploys) | Runs your own deploy or rollback script as it is, and reports it: who shipped what, the log, the outcome. On your server, as a job: rolls back when someone asks on the Deploys page |
| [`mybeast-secrets`](secrets/README.md) | [Secrets](https://services.my-beast.com/secrets) | Writes one environment's variables to a `.env`, or runs a command with them and writes nothing |
| [`mybeast-translations`](translations/README.md) | [Translations](https://services.my-beast.com/translations) | Sends an app's language files as they are, and writes the reviewed words back into them; fails CI while a language misses keys |
| [`mybeast-vulnerabilities`](vulnerabilities/README.md) | [Vulnerabilities](https://services.my-beast.com/vulnerabilities) | Pushes the packages an app runs (its lock files), and fails CI while a hole that bad is open |

## Install

Each is one file from the latest release. Put it anywhere on the `PATH`:

```bash
curl -fsSLo ~/.local/bin/mybeast-deploy https://github.com/my-beast/cli/releases/latest/download/mybeast-deploy
chmod +x ~/.local/bin/mybeast-deploy
mybeast-deploy --version
```

The same for `mybeast-secrets`, `mybeast-translations` and `mybeast-vulnerabilities`. Each release lists the files' SHA-256 sums in
`SHA256SUMS`, to check a download against:

```bash
cd ~/.local/bin && curl -fsSL https://github.com/my-beast/cli/releases/latest/download/SHA256SUMS | grep ' mybeast-deploy$' | shasum -a 256 -c -
```

In CI, pin a release instead of `latest`: `…/releases/download/v0.1.0/mybeast-deploy`.

## Tests

```bash
/bin/bash test.sh   # every command's tests, under the bash they must work with (3.2 on macOS); needs php for the stand-ins
```

Each command's own: `/bin/bash deploy/tests/run.sh`, and so on.

## Releasing

Add the version to `CHANGELOG.md`, then tag it: `git tag v0.2.0 && git push --tags`. The Release workflow runs the
tests on Linux and macOS and makes the GitHub release: the four files and `SHA256SUMS`.

## Licence

MIT.
