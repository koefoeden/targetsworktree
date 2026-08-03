# targets-worktree design

## Ownership

Worktree lifecycle support belongs in `shared-targets-runtime` because its
contracts are common to internal `{targets}` pipelines:

- discover the configured store;
- select an immutable source;
- expose cached values safely;
- coordinate setup, execution, and teardown;
- preserve generated worktree data.

A downstream pipeline supplies only its own `_targets.yaml`, Pixi environment,
endpoint targets, and optional runtime links. The implementation contains no
multiome target names, paths, or analysis logic.

Git remains responsible for branches and worktree registration. This tool owns
only the runtime environment inside an existing worktree.

## Single lifecycle

The public lifecycle has one route:

```text
unconfigured -> read-only -> writable-selective -> teardown
```

Configuration always links the configured store to an immutable snapshot.
There is no code-only/bare setup and no direct writable setup. The read-only
operation performs only configured-store discovery, immutable-source
selection, runtime-link setup, and state recording, so a separate less-safe
fast path would save little.

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
7. Only symlinks recorded by this setup are removed, and only while they still
   resolve to their recorded source.
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

Raw `tar_make()` remains unsupported in selective mode. Filesystem snapshot
immutability is the final protection if a raw file-target command accidentally
opens a retained symlink.

## Teardown and recovery

Teardown changes state to `removing`, checks for a live target process, and then
handles only recorded paths:

- snapshot store link: verify and unlink;
- incomplete staging directory: move to quarantine;
- selective writable store: move to quarantine;
- runtime and Pixi links created by setup: verify and unlink;
- adopted pre-existing exact links: leave untouched.

An RDS receipt is written before active state is removed. The command never
invokes `git worktree remove`; Git can remove the clean, unconfigured worktree
normally afterward.

## Feasibility evidence

The original private-pipeline helpers hard-coded `outputs/`, while the live
pipeline configures `pipelines/processing_and_aggregation/outputs`. Central
configured-store discovery removes that stale-path class of error.

Read-only measurements on the real pipeline found:

- 12,633 manifest rows;
- 41,653 metadata rows;
- 3,118 target vertices and 5,575 edges in a representative muscle
  genetic-enrichment endpoint closure;
- about 18.42 GB of target objects and 506 GB of store-relative file targets
  even for that static closure;
- roughly 39 GB transferred while a conventional complete store copy still
  reported about 1% progress.

A transparent filesystem copy-on-write layer was tested. OverlayFS worked with
a local lower directory but failed to copy up from the Isilon/NFS store with
`Value too large for defined data type`. `/dev/fuse` was unavailable. The
target-aware link view therefore avoids relying on unavailable filesystem
features.

The generic integration test proves nested-store discovery, the read-only
default and explicit conversion, preservation after failed conversion planning,
lock exclusion, foreign process rejection, live-store and escaping-path
rejection, object/file/dynamic-branch reuse, changed file and branch
reconciliation, unchanged immutable checksums, and quarantine.

A real `multiome-pipeline` smoke test additionally demonstrated:

- automatic selection of the latest Isilon snapshot;
- read-only `tar_read_raw()` through the configured nested store;
- a one-target selective store containing only physical metadata because the
  target was already outdated;
- a guarded head-node rebuild of
  `interesting_genes.FLINC_test`;
- a worktree-only command change reflected in the rebuilt result;
- unchanged snapshot metadata and object checksums;
- writable-store quarantine followed by clean, non-forced Git worktree
  removal;
- no interruption or mutation of the concurrently running base pipeline or its
  live store.

## Deliberate boundaries

- Full-store copying is not implemented. It remains an explicit manual fallback
  when selective execution is unsuitable.
- Store promotion is not implemented. Merge code and rerun targets in the base
  pipeline; absence in a selective store never means deletion from the base.
- Git worktree and branch creation/removal remain Git operations.
- Plan construction still pays the pipeline's graph-loading cost. On the real
  pipeline this was several minutes, although it avoided hundreds of gigabytes
  of copying. A future plan cache would need a defensible fingerprint over the
  pipeline script, sourced helpers, configuration, endpoint set, snapshot
  identity, and `{targets}` version before it could safely skip evaluation.
