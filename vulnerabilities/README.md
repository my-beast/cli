# mybeast-vulnerabilities

Sends an app's lock files to My Beast Vulnerabilities (`services.my-beast.com/vulnerabilities`) from its deploy script or
CI, and prints what is open there. The service reads the files and keeps only each package's name, version, licence and
whether it is direct or for development - never the files - and matches them against OSV's public advisories itself: the
list of what the app runs goes nowhere else. Bash and curl, nothing else; bash 3.2 (macOS's own) and up.

```bash
curl -fsSLo ~/.local/bin/mybeast-vulnerabilities https://github.com/my-beast/cli/releases/latest/download/mybeast-vulnerabilities
chmod +x ~/.local/bin/mybeast-vulnerabilities   # anywhere on your PATH; checking the download: ../README.md
```

## Settings

`MYBEAST_VULNERABILITIES_URL` (production `https://services.my-beast.com/vulnerabilities`, locally
`http://localhost:8024/vulnerabilities`) and `MYBEAST_VULNERABILITIES_SECRET` (a server key: the project's Settings →
Keys, shown once; or the one id put in Secrets - `_KEY` is read too), exported or in
`~/.config/mybeast/vulnerabilities.env` (`MYBEAST_VULNERABILITIES_CONFIG` names another file). The file is read, never
sourced, and refused when others can read it (`chmod 600`). The secret goes to curl on its standard input, never on its
command line.

## Use

From the app's folder (its git checkout says the commit; in CI without one, `GITHUB_SHA` or `CI_COMMIT_SHA`):

```bash
mybeast-vulnerabilities push --app shop --env production
mybeast-vulnerabilities push --app my-beast --env production --lock backend/composer.lock --lock frontend/package-lock.json
mybeast-vulnerabilities push --app shop --env staging --fail-on high      # CI: 1 while a high or critical is open
mybeast-vulnerabilities status --app shop --env production                # what is open now, without pushing
```

- **Which files:** without `--lock`, the `composer.lock` and `package-lock.json` of this folder. Each `composer.lock`
  goes with the `composer.json` beside it, which says what the app asks for itself ("direct"). `package-lock.json` is
  read in its versions 2 and 3 (npm 7 and later). yarn and pnpm are not read yet.
- **A push replaces** what runs in that app and environment; the service keeps the last 20 pushes. A finding gone at
  a later push is fixed by itself.
- **What it prints:** the packages taken, what is new and fixed since the last push, each open finding on a line (worst
  first, with the version that fixes it), and the app's page.
- **Exit codes:** 0 sent; 1 a finding at `--fail-on` or worse is open; 2 its own refusals (a bad option, no lock file,
  no settings); 3 the service did not take it (down, a refused secret, a file it cannot read). In a deploy script that
  must never stop for it, add `|| true`.

## Try it

```bash
export MYBEAST_VULNERABILITIES_URL=https://services.my-beast.com/vulnerabilities MYBEAST_VULNERABILITIES_SECRET=sk_…
cd examples/pinned-app     # an app pinned to versions with advisories
../../mybeast-vulnerabilities push --app pinned --env staging --fail-on high
```

## Tests

```bash
/bin/bash tests/run.sh
```

They run the CLI against `tests/fake-service.php` (a stand-in of the API on `php -S`) in a throwaway git checkout laid
out both ways an app may be (lock files at the top, or in backend/ and frontend/): what it sends (fields, each file byte for byte, its `composer.json`), both
layouts, `--fail-on`, `status`, the secret kept off curl's command line, refusals and their exit codes, the service
down, the config file, a commit from CI.
