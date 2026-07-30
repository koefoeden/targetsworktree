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

## Modes

| Mode | Store | Use |
|---|---|---|
| `code` | Absent | Code editing and tests that need no cached targets |
| `read-only` | Symlink to an immutable store snapshot | Inspection and `tar_read()` |
| `writable-selective` | Writable metadata plus snapshot links for the requested up-to-date closure | Focused target development and execution |

The base checkout and worktree must belong to the same Git repository and must
configure the same relative targets store. The command refuses to configure the
base checkout itself.

## Launcher

Use the executable launcher rather than calling the R script directly:

```bash
SHARED_RUNTIME=/projects/cbmr_shared/people/tqb695/non-GDPR/shared-targets-runtime

"$SHARED_RUNTIME/worktree/targets-worktree" configure \
  --project /path/to/pipeline-worktree \
  --base /path/to/pipeline \
  --mode read-only
```

The launcher:

1. resolves the Git worktree;
2. takes a non-waiting `flock` in that worktree's Git administrative directory;
3. uses the base pipeline's frozen Pixi environment during initial setup;
4. runs later commands from the worktree and its linked Pixi environment.

Set `TARGETS_WORKTREE_RSCRIPT=/path/to/Rscript` for projects that do not use
Pixi.

The lock covers setup, reconciliation, target execution, and teardown. Raw
`tar_make()` bypasses this protection and is unsupported in
`writable-selective` mode.

## Configure a code-only worktree

```bash
"$SHARED_RUNTIME/worktree/targets-worktree" configure \
  --project /path/to/pipeline-worktree \
  --base /path/to/pipeline \
  --mode code
```

If the base has `.pixi`, the tool links it into the worktree. An existing
symlink to that exact environment is accepted but not claimed as tool-owned.
Other existing paths fail closed.

## Configure read-only inspection

```bash
"$SHARED_RUNTIME/worktree/targets-worktree" configure \
  --project /path/to/pipeline-worktree \
  --base /path/to/pipeline \
  --mode read-only
```

By default, the command chooses the lexicographically latest complete store
under:

```text
<base configured store>/.snapshot/*
```

Use an explicit source when needed:

```bash
... configure ... --mode read-only --source /path/to/immutable/store
```

An explicit source must either be under a `.snapshot` path or have non-writable
targets metadata. The live base store is always rejected.

Read-only mode supports target inspection but filesystem permissions prevent
pipeline writes.

## Configure a selective writable store

Supply one or more endpoint target names:

```bash
"$SHARED_RUNTIME/worktree/targets-worktree" configure \
  --project /path/to/pipeline-worktree \
  --base /path/to/pipeline \
  --mode writable-selective \
  --target endpoint_a \
  --target endpoint_b
```

Setup temporarily exposes the immutable snapshot at the configured store path,
then:

1. computes the endpoints' dependency closure;
2. calls `tar_outdated()` against the snapshot and current worktree code;
3. copies only `meta/meta`;
4. links reusable target objects and store-relative file outputs;
5. leaves outdated outputs absent so `{targets}` writes them physically;
6. references external absolute and repository-relative inputs without copying
   them.

The final store is a physical writable directory. Snapshot-backed values inside
it are individually recorded symlinks.

The configured endpoints bound the selective store. A later run may select all
or a subset of them, but expanding the endpoint set requires teardown and
reconfiguration.

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

- code, read-only, and selective modes;
- immutable source selection and live-store rejection;
- exclusive launcher locking and foreign live-target PID rejection;
- containment through existing symlink ancestors;
- managed versus adopted runtime-link teardown;
- selective target-object and file-target reuse;
- dynamic branch ownership and rebuilding;
- reconciliation after a file-target command changes;
- physical scratch writes and unchanged source checksums;
- quarantine-first teardown.
