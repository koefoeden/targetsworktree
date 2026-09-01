# targetsworktree 0.1.1

- Use the package namespace directly instead of retaining the pre-package
  closure, function table, and forwarding wrappers.
- Keep lifecycle operations internal so they cannot bypass the lock-holding
  command.
- Remove unused plan and state fields, migration-era test names, and
  project-specific feasibility history.

# targetsworktree 0.1.0

- Port the targets-store worktree lifecycle from `shared-targets-runtime` into
  an installable R package.
- Preserve snapshot-backed read-only configuration, endpoint-scoped writable
  conversion, reconciliation, guarded execution, and quarantine-first teardown.
- Install the lock-holding `targets-worktree` command with the package.
