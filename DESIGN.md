# targets-worktree design

## Ownership

Worktree lifecycle support belongs in the `targetsworktree` package because its
contracts are common to `{targets}` pipelines:

- discover the configured store;
- select an immutable source;
- expose cached values safely;
- coordinate setup, execution, and teardown;
- preserve generated worktree data.

A downstream pipeline supplies only its own `_targets.yaml`, Pixi environment,
endpoint targets, and optional runtime links. The implementation contains no
project-specific target names, paths, or analysis logic.

Git remains responsible for branches and worktree registration. This tool owns
only the runtime environment inside an existing worktree.

## Single lifecycle

Creating a Git worktree does not opt it into this runtime. A worktree used only
for code or documentation editing, Git operations, or store-independent
validation remains unconfigured and outside the managed lifecycle. Only a
worktree that needs targets-store inspection or target execution enters the
public lifecycle, which has one route:

```text
unconfigured -> read-only -> writable-selective -> teardown
```

Configuration always links the configured store to an immutable snapshot.
There is no managed code-only/bare setup and no direct writable setup. A plain
Git worktree already supplies the code-only case without attaching a store.
The read-only operation performs configured-store discovery, immutable-source
selection, runtime-link setup, and state recording.

Conversion is explicit and endpoint-scoped. It retains the configured Pixi
environment, runtime links, source identity, and lifecycle record while
replacing the whole-store snapshot link with a selective physical store.

## Safety invariants

Every mutating operation must preserve these invariants:

1. The base checkout is never a configurable project.
2. The base and project are worktrees of one Git repository.
3. Both resolve the same normalized repository-relative targets store through
   `targets::tar_config_get("store")`.
4. The live base store is never a cache source.
5. Snapshot-backed paths are linked only from a filesystem snapshot under the
   base store, or from an explicit source whose metadata is not writable.
6. Existing regular files, directories, and unexpected symlinks are never
   replaced.
7. Only symlinks recorded by this setup are removed, and only while their link
   text still names the recorded source. A link whose source has since
   disappeared, such as an expired snapshot, therefore remains removable.
8. Writable stores are quarantined, never deleted, during teardown.
9. Setup, conversion, reconciliation, execution, and teardown are mutually
   exclusive for each worktree.
10. No operation promotes or deletes values in the base targets store.

Automatic snapshot discovery may be restricted to one caller-supplied regular
expression. A pattern with no complete match fails closed and never falls back
to another storage-managed snapshot namespace. Brief retries accommodate
transient empty directory listings from virtual snapshot directories.

The state record is stored in the worktree-specific Git administration
directory. It therefore cannot be mistaken for pipeline output, copied into a
selective store, or committed.

Storage-managed snapshots expire. Status reports a recorded source that no
longer exists, and conversion or reconciliation that still needs it fails with
that reason rather than a path-resolution error. Teardown identifies managed
links by their text, so it never depends on the source still existing.

## Pixi environment

A worktree linked to the base `.pixi` shares one environment with the base
checkout and every pipeline running from it. Pixi installs an environment to
match the lock file of the manifest it runs with, so a worktree lock that
differs from the base would rewrite that shared environment. Configuration
therefore links the base environment only when both lock files match, and uses
a worktree's own `.pixi` directory as it is.

The launcher runs R through `pixi run --as-is` with the manifest of the project
that owns the environment: the base when the worktree links it. `--as-is`
never installs or updates an environment. Pixi commands run by hand in a linked
worktree are outside this protection and should use `--as-is` as well.

## Selective-store conversion

Read-only configuration links the worktree store path to an immutable
snapshot. Conversion plans against this view because `tar_outdated()` must be
able to resolve store-relative file targets while comparing the current
worktree code with snapshot metadata.

The planner then:

1. computes the dependency closure of the requested endpoints with
   `tar_network()`;
2. computes outdated targets against the snapshot;
3. selects metadata rows owned by up-to-date closure targets, including dynamic
   branches;
4. classifies file-target paths as store-relative, project-relative, or
   external absolute paths;
5. validates that every reusable output and required input exists.

Materialization copies only `meta/meta`. Target objects and store-relative file
outputs are represented by individually recorded absolute symlinks. External
and project-relative inputs remain where they are. Outdated outputs remain
absent.

The store is constructed in a recorded staging directory and atomically renamed
into place. Planning failures occur before the state transition and leave the
read-only worktree unchanged. After the transition begins, ordinary R errors
restore the snapshot link and quarantine physical partial results. If the
process dies abruptly, the persistent `converting` state identifies the exact
staging path so teardown can quarantine it.

## Reconciliation

Code may change after setup. Before a guarded run, reconciliation computes
outdatedness for the selected configured endpoints and unlinks snapshot values
owned by newly outdated targets.

For dynamic metadata, a link is outdated when either its own metadata name or
its recorded parent target is outdated.

The reconciler handles each recorded destination as follows:

| Current destination | Action |
|---|---|
| Expected snapshot symlink, owner ready | Retain |
| Expected snapshot symlink, owner outdated | Unlink |
| Absent, owner ready | Recreate expected link |
| Physical output | Preserve and stop managing it |
| Symlink to another source | Fail closed |

If no managed links remain, there is nothing that can write through to the
snapshot, so the separate pre-run `tar_outdated()` scan is skipped.

The endpoint set is intentionally fixed at conversion time. Supporting
arbitrary expansion would require comparing the current mixed scratch store,
the snapshot, and potentially newer physical results. Reconfiguration is
simpler and unambiguous.

## Locking and target processes

The launcher holds a non-waiting `flock` under:

```text
<git worktree admin>/targets-worktree/lock
```

The descriptor survives the R process `exec` and remains held while callr or
Crew children run. The CLI refuses direct invocation without the launcher's
lock environment marker.

The lock prevents two lifecycle commands from racing, but another raw
`tar_make()` does not honor it. Selective reconciliation therefore also checks
the worktree store's recorded targets PID and refuses another live process.
The current guarded R PID is accepted after an in-process local run.

The PID check sees only processes on the current host, because `{targets}`
records a process ID without a hostname. On a shared filesystem the launcher
lock excludes guarded commands on other hosts, provided the filesystem supports
`flock` across clients. A raw `tar_make()` on another host is not detectable.

Raw `tar_make()` remains unsupported in selective mode. Filesystem snapshot
immutability is the final protection if a raw file-target command accidentally
opens a retained symlink.

## Teardown and recovery

Teardown first validates every recorded path and checks for a live target
process, so a refusal leaves the worktree ready. It then changes state to
`removing` and handles only recorded paths, skipping any that are already gone
so an interrupted teardown can resume:

- snapshot store link: verify and unlink;
- incomplete staging directory: move to quarantine;
- selective writable store: move to quarantine;
- runtime and Pixi links created by setup: verify and unlink;
- adopted pre-existing exact links: leave untouched.

An RDS receipt is written before active state is removed. The command never
invokes `git worktree remove`; Git can remove the clean, unconfigured worktree
normally afterward.

## Rationale and validation

Target-aware links avoid copying complete stores and do not depend on a
filesystem copy-on-write layer. Configured-store discovery also avoids assuming
a conventional store name.

The integration test is the executable contract. It covers nested stores,
snapshot selection, read-only inspection, selective object and file reuse,
dynamic branches, reconciliation, lock and process exclusion, path containment,
rollback, expired sources, Pixi link rules, immutable-source checksums, and
quarantine-first teardown. The Pixi launcher path is not exercised because the
test uses `TARGETS_WORKTREE_RSCRIPT`.

## Deliberate boundaries

- Full-store copying is not implemented. It remains an explicit manual fallback
  when selective execution is unsuitable.
- Store promotion is not implemented. Merge code and rerun targets in the base
  pipeline; absence in a selective store never means deletion from the base.
- Git worktree and branch creation/removal remain Git operations.
- Plan construction evaluates the pipeline graph; no plan cache is implemented.
