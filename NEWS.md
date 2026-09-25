# targetsworktree 0.1.2

- Identify managed symlinks by their link text, so teardown still removes a
  store link after its snapshot has expired. Status reports a missing source,
  and conversion and runs that need it stop with that reason.
- Run R through `pixi run --as-is` with the manifest of the project that owns
  the environment, so the launcher never rewrites a linked base environment.
- Link the base `.pixi` only when the worktree and base lock files match, and
  use a worktree's own `.pixi` directory instead of refusing it.
- Skip the project's R startup file for every command except `run`.
- Validate options per command, and keep Git's stderr out of parsed output.

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
