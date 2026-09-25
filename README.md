# targetsworktree

`targetsworktree` is an R package that gives a Git worktree its own safe
`{targets}` environment without copying an entire pipeline store. It is
pipeline-independent and reads the store path from the worktree's
`_targets.yaml` through `targets::tar_config_get("store")`.

See [DESIGN.md](DESIGN.md) for the safety invariants, reconciliation rules,
failure recovery, rationale, and deliberate boundaries.

The command manages the targets environment inside an existing Git worktree.
Git remains responsible for creating, merging, and removing the worktree
itself.

Do not run `configure` merely because a Git worktree was created. A worktree
used only for code or documentation editing, Git operations, or
store-independent validation should remain a plain, unconfigured Git worktree.
Use this command only when the worktree needs targets-store inspection or
target execution; every configuration attaches a targets store.

## Installation

Install a tagged version from GitHub:

```r
remotes::install_github("koefoeden/targetsworktree@v0.1.2")
```

The R environment used by the base checkout must contain `targetsworktree` and
its imports.

## Lifecycle

Only worktrees that need targets-store support enter the managed lifecycle.
Every managed worktree follows one route:

```text
unconfigured -> read-only -> writable-selective -> teardown
```

`configure` always creates a read-only worktree whose configured store is a
symlink to an immutable snapshot and immediately supports inspection and
`tar_read()`. There is no separate managed code-only or bare mode; ordinary
code-only worktrees stay outside this tool.

When target execution is needed, `convert` replaces that store link with
writable metadata plus individually recorded snapshot links for the requested
up-to-date dependency closure. Conversion preserves the worktree's Pixi and
runtime-link setup.

The base checkout and worktree must belong to the same Git repository and must
configure the same relative targets store. The command refuses to configure the
base checkout itself.

## Launcher

Resolve and use the installed executable. Lifecycle functions are deliberately
internal because the shell launcher owns locking:

```bash
targets_worktree_tool=$(Rscript --vanilla -e \
  'cat(targetsworktree::targets_worktree_executable())')

"$targets_worktree_tool" configure \
  --project /path/to/pipeline-worktree \
  --base /path/to/pipeline
```

The launcher:

1. resolves the Git worktree;
2. takes a non-waiting `flock` in that worktree's Git administrative directory;
3. runs R with `pixi run --as-is` through the project that owns the Pixi
   environment: the base during initial setup, and the base again later when
   the worktree links its `.pixi`;
4. skips the project's R startup file except for guarded runs.

`--as-is` never installs or updates an environment, so the launcher cannot
rewrite a shared base environment to match an older worktree lock file. Install
the environment with `pixi install` before configuring. Set
`TARGETS_WORKTREE_RSCRIPT=/path/to/Rscript` for projects that do not use Pixi.

The lock covers setup, conversion, reconciliation, target execution, and
teardown. Raw `tar_make()` bypasses this protection and is unsupported in
`writable-selective` mode.

## Configure a worktree

```bash
"$targets_worktree_tool" configure \
  --project /path/to/pipeline-worktree \
  --base /path/to/pipeline
```

By default, the command chooses the lexicographically latest complete store
under:

```text
<base configured store>/.snapshot/*
```

Lexicographic order is only meaningful within one naming family, where names
differ only in their digits. When that directory contains several families,
such as daily snapshots beside rotating replication snapshots, discovery
refuses to guess and lists the families; restrict it to one sortable family
with a regular expression. Snapshots expire, so a long-lived worktree can
outlive its source:

```bash
... configure \
  ... \
  --snapshot-pattern '^daily-[0-9]{4}-[0-9]{2}-[0-9]{2}$'
```

Discovery retries a transient empty listing three times. If no complete
snapshot matches the pattern, configuration fails rather than falling back to
another snapshot family.

Use an explicit source when needed:

```bash
... configure ... --source /path/to/immutable/store
```

An explicit source must either be under a `.snapshot` path or have non-writable
targets metadata. The live base store is always rejected. `--source` and
`--snapshot-pattern` are mutually exclusive.

If the base has `.pixi` and the worktree has no environment of its own, the tool
links the base environment into the worktree. An existing symlink to that exact
environment is accepted but not claimed as tool-owned. Linking requires the
worktree's `pixi.lock` to match the base's: otherwise Pixi would rewrite the
shared environment the next time it runs in the worktree. Run `pixi install` in
the worktree to give it its own environment instead; a worktree `.pixi`
directory is used as it is. Other existing paths fail closed.

Even with matching lock files, a linked worktree shares the base environment.
Run Pixi there only with `--as-is` or `--frozen --no-install`, or through the
launcher, so a later lock-file change cannot update the base environment. The
immutable store supports target inspection while refusing pipeline writes.

## Convert to a selective writable store

Supply one or more endpoint target names:

```bash
"$targets_worktree_tool" convert \
  --project /path/to/pipeline-worktree \
  --target endpoint_a \
  --target endpoint_b
```

Conversion uses the already configured immutable snapshot to:

1. compute the endpoints' dependency closure;
2. call `tar_outdated()` against the snapshot and current worktree code;
3. copy only `meta/meta`;
4. link reusable target objects and store-relative file outputs;
5. leave outdated outputs absent so `{targets}` writes them physically;
6. reference external absolute and repository-relative inputs without copying
   them.

The final store is a physical writable directory. Snapshot-backed values inside
it are individually recorded symlinks.

The configured endpoints bound the selective store. A later run may select all
or a subset of them, but expanding the endpoint set requires teardown and
fresh read-only configuration followed by conversion. A failed planning step
leaves the read-only setup unchanged. If materialization fails after mutation
begins, the tool restores the read-only store link and quarantines any physical
partial result.

## Guarded runs and reconciliation

```bash
"$targets_worktree_tool" run \
  --project /path/to/pipeline-worktree \
  --target endpoint_a
```

Immediately before execution, the tool:

- refuses another live targets process in this worktree;
- recomputes outdatedness when managed snapshot links exist;
- removes only recorded links whose owner targets are now outdated;
- refuses links that were redirected to an unexpected source;
- preserves physical worktree outputs;
- runs `tar_make()` while retaining the lifecycle lock.

If no managed links remain, reconciliation skips the redundant
`tar_outdated()` scan.

Use `--local` for a deliberately small head-node run:

```bash
"$targets_worktree_tool" run \
  --project /path/to/pipeline-worktree \
  --target small_target \
  --local
```

This installs a one-worker local Crew controller for the guarded R process and
restores the pipeline controller option afterward. Without `--local`, the
pipeline's normal controller configuration applies.

## Extra runtime links

Some projects need untracked runtime paths in addition to their targets store.
Supply each explicitly:

```bash
... configure ... \
  --link relative/path=/absolute/immutable/source
```

The destination must be a safe repository-relative path. An exact existing
symlink is accepted without claiming ownership; a regular file, directory, or
different symlink is a conflict. Teardown removes only links that this setup
created.

This keeps project-specific paths out of the shared implementation. A
downstream repository can provide a short wrapper with its standard `--link`
arguments.

## Status

```bash
"$targets_worktree_tool" status \
  --project /path/to/pipeline-worktree
```

State is stored outside the worktree and targets store, under:

```bash
git -C /path/to/pipeline-worktree \
  rev-parse --path-format=absolute --git-path targets-worktree/state.rds
```

It records the mode, configured store, source, endpoint closure, managed links,
and ownership of `.pixi` and runtime links. Status reports a recorded source
that no longer exists, such as an expired snapshot; conversion and runs that
still depend on it refuse to continue until the worktree is reconfigured.

## Teardown

```bash
"$targets_worktree_tool" teardown \
  --project /path/to/pipeline-worktree
```

Teardown:

- validates every recorded path before changing anything, so a refusal leaves
  the worktree ready, and skips recorded links that are already gone, so an
  interrupted teardown can be rerun;
- refuses a live targets process on the current host;
- removes only symlinks whose destinations and link text match recorded
  state, including links whose snapshot has since expired;
- moves a writable store atomically to
  `<worktree-parent>/.targets-worktree-quarantine/`;
- saves a teardown receipt in the worktree's Git administrative directory;
- removes the active state record.

It never deletes a writable store, calls `rsync --delete`, removes a Git
worktree, or deletes a branch. After restoring or committing ordinary code
changes, remove the now-unconfigured worktree normally:

```bash
git worktree remove /path/to/pipeline-worktree
```

Quarantined stores are retained until a human explicitly decides they are no
longer needed.

## Tests

Build and check the package through an R environment that provides its imports:

```bash
R CMD build .
R CMD check --no-manual targetsworktree_*.tar.gz
```

The test creates a disposable nested-store targets project and verifies:

- side-effect-free status checks before configuration;
- per-command option validation;
- the read-only default and explicit selective conversion;
- expired-source reporting and teardown;
- refusal of mixed snapshot families without a pattern;
- validate-first, resumable teardown;
- Pixi linking only for matching lock files, and worktree environments;
- preservation of read-only state after failed conversion planning;
- immutable source selection and live-store rejection;
- exclusive launcher locking and foreign live-target PID rejection;
- containment through existing symlink ancestors;
- managed versus adopted runtime-link teardown;
- selective target-object and file-target reuse;
- dynamic branch ownership and rebuilding;
- reconciliation after a file-target command changes;
- physical scratch writes and unchanged source checksums;
- quarantine-first teardown.
