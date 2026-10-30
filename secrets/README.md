# mybeast-secrets

MyBeast Secrets on a machine: one environment's variables, read with a service token. Bash and curl, nothing else;
bash 3.2 (macOS) and up.

## Settings

```bash
export MYBEAST_SECRETS_URL=https://services.my-beast.com/secrets
export MYBEAST_SECRETS_TOKEN=st_….…   # a service token of one environment: the project's Secrets → Tokens page
```

A token reads its own environment and nothing else, and every read is in the project's audit log. It goes to curl on
its standard input, never on its command line.

## Use

```bash
mybeast-secrets pull                    # writes .env, readable by its owner only
mybeast-secrets pull --out config/.env  # somewhere else; --out - prints it
mybeast-secrets run -- php artisan serve # runs a command with the variables, and writes nothing
```

- `pull` writes the file next to its place and moves it there whole, so a reader never sees half of it. It overwrites
  only a file it wrote itself (its first line says so); `--force` overwrites any.
- `run` reads each line of the answer as `export NAME=$'…'` with every unsafe byte as `\xHH`, decodes it and never
  runs it: a line of any other shape stops it before the command starts. The command's exit status is its own.
- A refused token, too many reads, an address that is not https: it says so in words and ends 1.

## Tests

```bash
/bin/bash tests/run.sh   # against a stand-in for curl that answers what the API answers (tests/fixtures)
```

`tests/fixtures` are the API's two answers for six awkward values (quotes, a newline, Unicode, an empty one, a `;`),
rendered by services' own `DotEnv` and `ShellExport`; `make sdk-check` in the MyBeast folder says when they drift.
