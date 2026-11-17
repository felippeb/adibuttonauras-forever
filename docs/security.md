# How this pipeline is protected

Short version: one third-party action, pinned by commit; the release tool has
no dependencies at all; the CurseForge token exists in exactly one step of one
job, behind an environment approval; and the bytes that get uploaded are built
from the tagged commit and audited before they leave the runner.

## Trust boundaries

```
push / PR ──► verify job          (contents: read, no secrets)
                 ├─ pip install --require-hashes (3 packages, hashes pinned)
                 ├─ Lua parse of every .lua
                 ├─ unit tests for the release + audit tools
                 ├─ zip built by build-zip.ps1
                 └─ archive audited for secrets, paths, stray files

tag / manual ──► publish job      (environment: curseforge, contents: write)
                 ├─ zip rebuilt from the same commit
                 ├─ archive audited again
                 ├─ upload via tools/cf_release.py (stdlib only)
                 └─ gh release create
```

The publish job installs nothing and runs no third-party action. Everything it
executes is either preinstalled on the GitHub runner (`pwsh`, `python3`, `gh`)
or code from this repository. If a dependency somewhere in the world is
compromised, it cannot execute in the same process that can read the token.

## What is pinned

| Thing | Pin |
| --- | --- |
| `actions/checkout` | commit SHA `3d3c42e` (v7.0.1), `persist-credentials: false` |
| `luaparser` | `4.2.0` + wheel sha256 |
| `antlr4-python3-runtime` | `4.13.2` + wheel sha256 |
| `multimethod` | `2.1` + wheel sha256 |
| Runner | `ubuntu-24.04`, not `ubuntu-latest` |
| CurseForge game version | numeric id resolved at run time, never a name |

`--require-hashes` means pip refuses any wheel whose bytes differ from what is
pinned here, including a re-published version with the same number.

## The token

- One repository **secret** (`CURSEFORGE_API_TOKEN`) attached to the
  `curseforge` **environment**, which has required reviewers.
- Exposed only as an environment variable on the single upload step. It is
  never passed on a command line, never written to a file, never echoed, and
  never interpolated into a `run:` string by the workflow engine — so it cannot
  leak through a shell injection from an input.
- `persist-credentials: false` on checkout, so the `GITHUB_TOKEN` is not left in
  `.git/config` for later steps.
- The CurseForge token is account-wide. Rotating it is one click in the author
  dashboard; if it ever appears in a log, a screenshot or a commit, rotate it
  before doing anything else.

## What the audit rejects

`tools/audit_zip.py` runs on the exact archive that will be uploaded:

- GitHub tokens, AWS keys, private key blocks, `Authorization: Bearer …`,
  `X-Api-Token: …`
- Windows and Unix home directories, `WTF\Account\…`
- `.bak`, `.orig`, `.zip`, `.exe`, `.dll`, `.ps1`, `.env`, `.key`, `.pem`, logs
- `SavedVariables/`, `WTF/`, `.git/`, `__pycache__/`, editor folders
- zip-slip entries (`..`, absolute paths, backslashes)
- anything whose extension is not a normal addon file type

Its test suite builds deliberately compromised archives to prove each rule
fires. A gate that has never failed is not a gate.

## Deliberate non-goals

- No `pull_request_target`, no `workflow_run`, no `issue_comment` triggers.
  Those are the shapes that hand a secret to untrusted code.
- No artifact pass-through between jobs. The publish job rebuilds from the
  commit instead of downloading a file another job produced, so there is no
  artifact-substitution step.
- No `security-events: write`, no `id-token: write`, no extra scopes. The
  publish job asks for `contents: write` because `gh release create` needs it,
  and nothing else.

## If something goes wrong

1. Rotate the CurseForge token (author dashboard → API tokens), then
   `gh secret set CURSEFORGE_API_TOKEN`.
2. Delete the bad file from the project's Files tab.
3. If a workflow change was involved, `git revert` it and re-run `ci` before
   tagging again.
4. Check `gh run list --repo felippeb/adibuttonauras-forever` for unexpected
   runs; delete and re-create the environment if its reviewers changed.
