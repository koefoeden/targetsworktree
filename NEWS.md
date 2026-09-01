# targetsworktree 0.1.0

- Port the targets-store worktree lifecycle from `shared-targets-runtime` into
  an installable R package.
- Preserve snapshot-backed read-only configuration, endpoint-scoped writable
  conversion, reconciliation, guarded execution, and quarantine-first teardown.
- Install the lock-holding `targets-worktree` command with the package.
