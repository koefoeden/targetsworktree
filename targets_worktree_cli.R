#!/usr/bin/env Rscript

arguments <- commandArgs(trailingOnly = TRUE)
root <- Sys.getenv("TARGETS_WORKTREE_ROOT")
if (!nzchar(root)) {
  script <- sub("^--file=", "", commandArgs()[grepl("^--file=", commandArgs())])
  root <- dirname(normalizePath(script, mustWork = TRUE))
}
source(file.path(root, "R", "targets_worktree_core.R"))

usage <- function(status = 0L) {
  cat(
    "Usage:\n",
    "  targets-worktree configure --project PATH --base PATH --mode MODE [options]\n",
    "  targets-worktree status --project PATH\n",
    "  targets-worktree reconcile --project PATH [--target NAME ...]\n",
    "  targets-worktree run --project PATH [--target NAME ...] [--local]\n",
    "  targets-worktree teardown --project PATH\n",
    "\n",
    "Configure options:\n",
    "  --mode code|read-only|writable-selective\n",
    "  --source PATH       Immutable targets-store source; default: latest snapshot\n",
    "  --target NAME       Endpoint target; repeat as needed\n",
    "  --link REL=SOURCE   Extra runtime symlink; repeat as needed\n",
    sep = ""
  )
  quit(status = status)
}

parse_options <- function(values) {
  output <- list(
    project = getwd(),
    base = NULL,
    mode = NULL,
    source = NULL,
    target = character(),
    link = character(),
    local = FALSE
  )
  index <- 1L
  while (index <= length(values)) {
    option <- values[[index]]
    if (!startsWith(option, "--")) {
      stop("Unexpected argument: ", option)
    }
    name <- substring(option, 3L)
    if (!name %in% names(output)) {
      stop("Unknown option: ", option)
    }
    if (name == "local") {
      output$local <- TRUE
      index <- index + 1L
      next
    }
    if (index == length(values)) {
      stop("Missing value for option: ", option)
    }
    value <- values[[index + 1L]]
    if (name %in% c("target", "link")) {
      output[[name]] <- c(output[[name]], value)
    } else {
      if (!is.null(output[[name]]) && name != "project") {
        stop("Option supplied more than once: ", option)
      }
      output[[name]] <- value
    }
    index <- index + 2L
  }
  output
}

parse_links <- function(values) {
  if (length(values) == 0L) {
    return(character())
  }
  pieces <- strsplit(values, "=", fixed = TRUE)
  valid <- lengths(pieces) >= 2L & vapply(pieces, function(value) {
    nzchar(value[[1L]]) && nzchar(paste(value[-1L], collapse = "="))
  }, logical(1))
  if (!all(valid)) {
    stop("--link values must use REL=SOURCE.")
  }
  sources <- vapply(
    pieces,
    function(value) paste(value[-1L], collapse = "="),
    character(1)
  )
  names(sources) <- vapply(pieces, `[[`, character(1), 1L)
  sources
}

print_status <- function(value) {
  scalar <- c("project", "base", "mode", "phase", "store", "source")
  for (name in scalar) {
    item <- value[[name]]
    if (!is.null(item)) {
      cat(sprintf("%-18s %s\n", paste0(name, ":"), paste(item, collapse = ", ")))
    }
  }
  cat(sprintf("%-18s %s\n", "targets:", paste(value$targets, collapse = ", ")))
  cat(sprintf("%-18s %d\n", "closure targets:", value$closure_targets))
  cat(sprintf("%-18s %d\n", "outdated targets:", value$outdated_targets))
  cat(sprintf("%-18s %d\n", "managed links:", value$managed_links))
  if (!is.null(value$quarantine)) {
    cat(sprintf("%-18s %s\n", "quarantine:", value$quarantine))
  }
  invisible(value)
}

if (length(arguments) == 0L || arguments[[1L]] %in% c("-h", "--help", "help")) {
  usage()
}
if (!identical(Sys.getenv("TARGETS_WORKTREE_LOCK_HELD"), "1")) {
  stop("Invoke this script through the targets-worktree launcher.")
}

command <- arguments[[1L]]
options <- parse_options(arguments[-1L])

if (command == "configure") {
  if (is.null(options$base) || is.null(options$mode)) {
    stop("configure requires --base and --mode.")
  }
  result <- shared_targets_worktree$configure(
    project = options$project,
    base = options$base,
    mode = options$mode,
    target_names = options$target,
    source = options$source,
    runtime_links = parse_links(options$link)
  )
  print_status(result)
} else if (command == "status") {
  print_status(shared_targets_worktree$status(options$project))
} else if (command == "reconcile") {
  result <- shared_targets_worktree$reconcile(
    options$project,
    if (length(options$target) == 0L) NULL else options$target
  )
  cat("outdated targets:", paste(result$outdated, collapse = ", "), "\n")
  print_status(shared_targets_worktree$status(options$project))
} else if (command == "run") {
  shared_targets_worktree$run(
    options$project,
    if (length(options$target) == 0L) NULL else options$target,
    local = options$local
  )
  print_status(shared_targets_worktree$status(options$project))
} else if (command == "teardown") {
  result <- shared_targets_worktree$teardown(options$project)
  cat("mode:", result$mode, "\n")
  if (!is.null(result$quarantine)) {
    for (path in result$quarantine) {
      cat("quarantine:", path, "\n")
    }
  }
  cat("receipt:", result$receipt, "\n")
} else {
  stop("Unknown command: ", command)
}
