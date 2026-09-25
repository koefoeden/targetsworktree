targets_worktree_usage <- function() {
  cat(
    "Usage:\n",
    "  targets-worktree configure --project PATH --base PATH [options]\n",
    "  targets-worktree status --project PATH\n",
    "  targets-worktree run --project PATH --target NAME [--target NAME ...] [--local]\n",
    "  targets-worktree teardown --project PATH\n",
    "\n",
    "Configure options:\n",
    "  --source PATH              Immutable targets-store source\n",
    "  --snapshot-pattern REGEX   Restrict automatic snapshot discovery by name\n",
    "  --link REL=SOURCE          Extra runtime symlink; repeat as needed\n",
    "\n",
    "Run options:\n",
    "  --target NAME   Target to make; repeat as needed\n",
    "  --local         Use a one-worker local Crew controller\n",
    sep = ""
  )
  invisible(NULL)
}

command_options <- list(
  configure = c("project", "base", "source", "snapshot-pattern", "link"),
  status = "project",
  run = c("project", "target", "local"),
  teardown = "project"
)

parse_targets_worktree_options <- function(command, values) {
  allowed <- command_options[[command]]
  if (is.null(allowed)) {
    stop("Unknown command: ", command)
  }
  output <- list(target = character(), link = character(), local = FALSE)
  index <- 1L
  while (index <= length(values)) {
    option <- values[[index]]
    name <- sub("^--", "", option)
    if (identical(name, option) || !name %in% allowed) {
      stop("Unexpected argument for ", command, ": ", option)
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
    } else if (!is.null(output[[name]])) {
      stop("Option supplied more than once: ", option)
    } else {
      output[[name]] <- value
    }
    index <- index + 2L
  }
  output$project <- output$project %||% getwd()
  output
}

parse_targets_worktree_links <- function(values) {
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

print_targets_worktree_status <- function(value) {
  scalar <- c(
    "project", "base", "mode", "phase", "store", "source",
    "snapshot_pattern"
  )
  for (name in scalar) {
    item <- value[[name]]
    if (!is.null(item)) {
      label <- gsub("_", " ", name, fixed = TRUE)
      cat(sprintf("%-18s %s\n", paste0(label, ":"), paste(item, collapse = ", ")))
    }
    if (name == "source" && isTRUE(value$source_missing)) {
      cat(sprintf("%-18s %s\n", "source status:", "missing (snapshot expired?)"))
    }
  }
  cat(sprintf("%-18s %s\n", "targets:", paste(value$targets, collapse = ", ")))
  cat(sprintf("%-18s %d\n", "closure targets:", value$closure_targets))
  cat(sprintf("%-18s %d\n", "outdated targets:", value$outdated_targets))
  cat(sprintf("%-18s %d\n", "managed links:", value$managed_links))
  cat(sprintf("%-18s %s\n", "worktree locked:", if (value$locked) "yes" else "no"))
  if (!is.null(value$quarantine)) {
    cat(sprintf("%-18s %s\n", "quarantine:", value$quarantine))
  }
  invisible(value)
}

targets_worktree_cli <- function(arguments = commandArgs(trailingOnly = TRUE)) {
  if (length(arguments) == 0L || arguments[[1L]] %in% c("-h", "--help", "help")) {
    targets_worktree_usage()
    return(invisible(NULL))
  }
  require_targets_worktree_lock()

  command <- arguments[[1L]]
  options <- parse_targets_worktree_options(command, arguments[-1L])

  if (command == "configure") {
    if (is.null(options$base)) {
      stop("configure requires --base.")
    }
    result <- configure(
      project = options$project,
      base = options$base,
      source = options$source,
      snapshot_pattern = options[["snapshot-pattern"]],
      runtime_links = parse_targets_worktree_links(options$link)
    )
    print_targets_worktree_status(result)
  } else if (command == "status") {
    print_targets_worktree_status(status(options$project))
  } else if (command == "run") {
    if (length(options$target) == 0L) {
      stop("run requires at least one --target.")
    }
    print_targets_worktree_status(
      run(options$project, options$target, local = options$local)
    )
  } else if (command == "teardown") {
    result <- teardown(options$project)
    cat("mode:", result$mode, "\n")
    if (!is.null(result$quarantine)) {
      for (path in result$quarantine) {
        cat("quarantine:", path, "\n")
      }
    }
    cat("receipt:", result$receipt, "\n")
  }
  invisible(NULL)
}
