require_targets_worktree_lock <- function() {
  if (!identical(Sys.getenv("TARGETS_WORKTREE_LOCK_HELD"), "1")) {
    stop("Use the targets-worktree launcher so the operation holds its lock.")
  }
}

#' Locate the installed targets-worktree command
#'
#' @return The absolute path to the installed command.
#' @export
targets_worktree_executable <- function() {
  system.file("exec", "targets-worktree", package = "targetsworktree", mustWork = TRUE)
}

#' Manage a targets store in a Git worktree
#'
#' These functions implement the managed lifecycle
#' `unconfigured -> read-only -> writable-selective -> teardown`. Invoke them
#' through the installed `targets-worktree` command so each operation holds the
#' worktree lock.
#'
#' @param project Absolute path to an existing Git worktree.
#' @param base Absolute path to the base checkout.
#' @param source Optional immutable targets-store source.
#' @param snapshot_pattern Optional regular expression restricting automatic
#'   snapshot discovery.
#' @param runtime_links Named character vector mapping repository-relative
#'   destinations to immutable sources.
#' @param target_names Character vector of endpoint target names.
#' @param local Whether to use a one-worker local controller.
#'
#' @return `targets_worktree_configure()`, `targets_worktree_convert()`,
#'   `targets_worktree_run()`, and `targets_worktree_status()` return lifecycle
#'   status. `targets_worktree_reconcile()` returns reconciliation details.
#'   `targets_worktree_teardown()` returns teardown and quarantine details.
#' @export
targets_worktree_configure <- function(
  project,
  base,
  source = NULL,
  snapshot_pattern = NULL,
  runtime_links = character()
) {
  require_targets_worktree_lock()
  targets_worktree_core$configure(
    project = project,
    base = base,
    source = source,
    snapshot_pattern = snapshot_pattern,
    runtime_links = runtime_links
  )
}

#' @rdname targets_worktree_configure
#' @export
targets_worktree_convert <- function(project, target_names) {
  require_targets_worktree_lock()
  targets_worktree_core$convert(project, target_names)
}

#' @rdname targets_worktree_configure
#' @export
targets_worktree_reconcile <- function(project, target_names = NULL) {
  require_targets_worktree_lock()
  targets_worktree_core$reconcile(project, target_names)
}

#' @rdname targets_worktree_configure
#' @export
targets_worktree_run <- function(project, target_names = NULL, local = FALSE) {
  require_targets_worktree_lock()
  targets_worktree_core$run(project, target_names, local)
}

#' @rdname targets_worktree_configure
#' @export
targets_worktree_status <- function(project) {
  require_targets_worktree_lock()
  targets_worktree_core$status(project)
}

#' @rdname targets_worktree_configure
#' @export
targets_worktree_teardown <- function(project) {
  require_targets_worktree_lock()
  targets_worktree_core$teardown(project)
}
