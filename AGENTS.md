# targetsworktree

Preserve the lifecycle and safety invariants in `DESIGN.md`. The package owns
targets-store support inside an existing Git worktree; Git continues to own
worktree and branch creation or removal.

Keep the implementation pipeline-independent. Do not add project target names,
store paths, snapshot policies, or analysis logic.

Run `R CMD check --no-manual` and `tests/integration.R` after lifecycle changes.
