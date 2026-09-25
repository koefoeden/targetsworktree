# targetsworktree

`targetsworktree` gives an existing Git worktree of a `{targets}` pipeline its
own safe targets store, backed by an immutable snapshot of the base store
instead of a full copy. It is pipeline-independent and finds the store through
`targets::tar_config_get("store")`. [DESIGN.md](DESIGN.md) holds the safety
invariants, recovery rules, and rationale.

Use it only when a worktree must read the targets store or run targets. Leave
worktrees for code, documentation, Git operations, or store-independent checks
unconfigured. Git still creates, merges, and removes worktrees and branches.

## Install

Install into the R environment of the base checkout:

```r
remotes::install_github("koefoeden/targetsworktree@v0.2.0")
```

## Lifecycle

```text
unconfigured -> read-only -> writable-selective -> teardown
```

| Step | Command | Effect |
|---|---|---|
| Configure | `configure` | Links the store to a snapshot, for `tar_read()` and other inspection. |
| First run | `run` | Replaces the link with a writable store and locks the Git worktree. |
| Later runs | `run` | Links the snapshot values each run needs; rebuilt values stay physical. |
| Teardown | `teardown` | Quarantines the writable store and removes the tool's links and lock. |

Then remove the unconfigured worktree with `git worktree remove`.

**The lock.** Git ignores the writable store, so a plain `git worktree remove`
would delete every value the worktree rebuilt, without a prompt. The lock makes
Git refuse, even with the single `--force` that editors such as VS Code pass:

```text
cannot remove a locked working tree, lock reason: targetsworktree: run teardown before removing this worktree
```

Run `teardown` rather than overriding the lock. `status` and
`git worktree list` show it, and teardown removes only a lock with this reason.

## Commands

Resolve the launcher from the base checkout's R environment and always use it.
It holds a per-worktree `flock` for every command, and runs R through
`pixi run --as-is` with the manifest that owns the environment, so it never
installs or updates one. It loads the project's R startup file only for `run`.
Run `pixi install` before configuring, or set
`TARGETS_WORKTREE_RSCRIPT=/path/to/Rscript` for a project without Pixi.

```bash
targets_worktree_tool=$(Rscript --vanilla -e \
  'cat(targetsworktree::targets_worktree_executable())')
```

### configure

```bash
"$targets_worktree_tool" configure --project WORKTREE --base BASE_CHECKOUT \
  [--snapshot-pattern REGEX | --source STORE] [--link PATH=SOURCE ...]
```

- The worktree and base must belong to one repository and configure the same
  store. The base checkout itself is refused.
- By default the latest complete snapshot under `<base store>/.snapshot/` is
  used. If several naming families exist there, such as dailies beside
  replication snapshots, configuration refuses to guess: pass
  `--snapshot-pattern` for one family. A pattern without a match fails; there
  is no fallback.
- `--source` must lie under a `.snapshot` path or have read-only metadata. The
  live base store is always refused.
- `--link` adds a runtime symlink at a repository-relative path. An identical
  existing link is adopted but not owned; any other existing path conflicts.
- Pixi: a worktree with its own `.pixi` keeps it. Otherwise the base `.pixi`
  is linked, but only when both `pixi.lock` files match. In a linked worktree,
  run Pixi only with `--as-is` or `--frozen --no-install`, or it can rewrite the
  shared environment.

### run

```bash
"$targets_worktree_tool" run --project WORKTREE \
  --target NAME [--target NAME ...] [--local]
```

- Planning only reads, so an unknown target or a broken pipeline leaves the
  worktree unchanged.
- Each run links the snapshot values of the requested targets and their
  dependencies whose metadata still matches the snapshot, unlinks those whose
  targets are outdated, and runs `tar_make()` under the lock.
- `--local` uses a one-worker local Crew controller, for small runs in the
  current allocation or on the head node. Otherwise the pipeline's controllers
  apply.
- Never run raw `tar_make()` in a converted worktree: it bypasses the lock and
  the checks that keep writes out of the snapshot.

### status

```bash
"$targets_worktree_tool" status --project WORKTREE
```

Reports the mode, phase, store, source, targets run, link counts, lock, and
quarantine. `source status: missing` means the snapshot has expired: runs
refuse, but teardown still works, after which the worktree can be configured
again. State
lives in the worktree's Git administrative directory, never in the worktree or
its store.

### teardown

```bash
"$targets_worktree_tool" teardown --project WORKTREE
git worktree remove WORKTREE
```

Teardown validates every recorded path and refuses while a targets process is
live, so a refusal leaves the worktree ready. An interrupted teardown can be
rerun. It then:

- moves a writable store to `<worktree parent>/.targets-worktree-quarantine/`;
- removes only the symlinks it recorded, including links to expired snapshots;
- removes its Git worktree lock;
- writes a receipt and removes the state record.

It never deletes a store, the worktree, or a branch. Quarantined stores stay
until a human decides they are no longer needed. Commit or restore code changes
before removing the worktree.

## Tests

```bash
R CMD build .
R CMD check --no-manual targetsworktree_*.tar.gz
```

`tests/integration.R` runs the full lifecycle on a disposable pipeline, is the
executable contract, and prints each property it verifies. To iterate faster,
run it alone from a temporary library:

```bash
lib=$(mktemp -d) && R CMD INSTALL --library="$lib" . &&
  R_LIBS="$lib" Rscript tests/integration.R
```
