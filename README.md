# targets-worktree

`targets-worktree` gives a Git worktree its own safe `{targets}` environment
without copying an entire pipeline store. It is pipeline-independent and reads
the store path from the worktree's `_targets.yaml` through
`targets::tar_config_get("store")`.

See [DESIGN.md](DESIGN.md) for the safety invariants, reconciliation rules,
failure recovery, feasibility measurements, and deliberate boundaries.

The command manages the targets environment inside an existing Git worktree.
Git remains responsible for creating, merging, and removing the worktree
itself.

## Lifecycle

Every managed worktree follows one route:

```text
unconfigured -> read-only -> writable-selective -> teardown
```

`configure` always creates a read-only worktree whose configured store is a
symlink to an immutable snapshot. This setup is cheap enough for code editing
and immediately supports inspection and `tar_read()`. There is no separate
code-only or bare mode.

When target execution is needed, `convert` replaces that store link with
writable metadata plus individually recorded snapshot links for the requested
up-to-date dependency closure. Conversion preserves the worktree's Pixi and
runtime-link setup.

The base checkout and worktree must belong to the same Git repository and must
configure the same relative targets store. The command refuses to configure the
base checkout itself.

## Launcher

Use the executable launcher rather than calling the R script directly:

```bash
SHARED_RUNTIME=/projects/cbmr_shared/people/tqb695/non-GDPR/shared-targets-runtime

"$SHARED_RUNTIME/worktree/targets-worktree" configure \
  --project /path/to/pipeline-worktree \
  --base /path/to/pipeline
```

The launcher:

1. resolves the Git worktree;
2. takes a non-waiting `flock` in that worktree's Git administrative directory;
3. uses the base pipeline's frozen Pixi environment during initial setup;
4. runs later commands from the worktree and its linked Pixi environment.

Set `TARGETS_WORKTREE_RSCRIPT=/path/to/Rscript` for projects that do not use
Pixi.

The lock covers setup, conversion, reconciliation, target execution, and
teardown. Raw `tar_make()` bypasses this protection and is unsupported in
`writable-selective` mode.

## Configure a worktree

```bash
"$SHARED_RUNTIME/worktree/targets-worktree" configure \
  --project /path/to/pipeline-worktree \
  --base /path/to/pipeline
```

By default, the command chooses the lexicographically latest complete store
under:

```text
<base configured store>/.snapshot/*
```

When that directory contains multiple snapshot families, restrict discovery to
one lexicographically sortable name family with a regular expression:

```bash
... configure \
  ... \
  --snapshot-pattern '^daily-[0-9]{4}-[0-9]{2}-[0-9]{2}$'
```

Discovery retries a transient empty listing three times. If no complete
snapshot matches the pattern, configuration fails rather than falling back to
another snapshot family.

The CBMR Isilon daily-policy pattern is:

```bash
--snapshot-pattern '^60-Research-daily-20D-[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}:[0-9]{2}$'
```

Use an explicit source when needed:

```bash
... configure ... --source /path/to/immutable/store
```

An explicit source must either be under a `.snapshot` path or have non-writable
targets metadata. The live base store is always rejected. `--source` and
`--snapshot-pattern` are mutually exclusive.

If the base has `.pixi`, the tool links it into the worktree. An existing
symlink to that exact environment is accepted but not claimed as tool-owned.
Other existing paths fail closed. The immutable store supports target
inspection while refusing pipeline writes.

## Convert to a selective writable store

Supply one or more endpoint target names:

```bash
"$SHARED_RUNTIME/worktree/targets-worktree" convert \
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
"$SHARED_RUNTIME/worktree/targets-worktree" run \
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
"$SHARED_RUNTIME/worktree/targets-worktree" run \
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
"$SHARED_RUNTIME/worktree/targets-worktree" status \
  --project /path/to/pipeline-worktree
```

State is stored outside the worktree and targets store, under:

```bash
git -C /path/to/pipeline-worktree \
  rev-parse --path-format=absolute --git-path targets-worktree/state.rds
```

It records the mode, configured store, source, endpoint closure, managed links,
and ownership of `.pixi` and runtime links.

## Teardown

```bash
"$SHARED_RUNTIME/worktree/targets-worktree" teardown \
  --project /path/to/pipeline-worktree
```

Teardown:

- refuses a live targets process;
- removes only symlinks whose destinations and sources match recorded state;
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

Run the generic integration test through any downstream Pixi environment that
provides `{targets}`:

```bash
pixi run --frozen \
  --manifest-path /path/to/pipeline/pixi.toml \
  Rscript worktree/tests/integration.R
```

The test creates a disposable nested-store targets project and verifies:

- the read-only default and explicit selective conversion;
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
