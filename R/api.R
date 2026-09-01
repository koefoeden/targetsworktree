require_targets_worktree_lock <- function() {
  if (!identical(Sys.getenv("TARGETS_WORKTREE_LOCK_HELD"), "1")) {
    stop("Use the targets-worktree launcher so the operation holds its lock.")
  }
}

targets_worktree_executable <- function() {
  system.file("exec", "targets-worktree", package = "targetsworktree", mustWork = TRUE)
}
