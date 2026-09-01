\name{targets_worktree_configure}
\alias{targets_worktree_configure}
\alias{targets_worktree_convert}
\alias{targets_worktree_reconcile}
\alias{targets_worktree_run}
\alias{targets_worktree_status}
\alias{targets_worktree_teardown}
\title{Manage a Targets Store in a Git Worktree}
\usage{
targets_worktree_configure(
  project,
  base,
  source = NULL,
  snapshot_pattern = NULL,
  runtime_links = character()
)

targets_worktree_convert(project, target_names)

targets_worktree_reconcile(project, target_names = NULL)

targets_worktree_run(project, target_names = NULL, local = FALSE)

targets_worktree_status(project)

targets_worktree_teardown(project)
}
\arguments{
\item{project}{Absolute path to an existing Git worktree.}

\item{base}{Absolute path to the base checkout.}

\item{source}{Optional immutable targets-store source.}

\item{snapshot_pattern}{Optional regular expression restricting automatic
snapshot discovery.}

\item{runtime_links}{Named character vector mapping repository-relative
destinations to immutable sources.}

\item{target_names}{Character vector of endpoint target names.}

\item{local}{Whether to use a one-worker local controller.}
}
\value{
Configuration, conversion, execution, and status return lifecycle status.
Reconciliation returns reconciliation details. Teardown returns teardown and
quarantine details.
}
\description{
Implements the managed lifecycle from read-only snapshot access through
endpoint-scoped execution and quarantine-first teardown. Invoke these functions
through the installed \code{targets-worktree} command so the operation holds
the worktree lock.
}
