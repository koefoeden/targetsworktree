# Git, path, ownership, and state primitives -----------------------------------

normalize_directory <- function(path, label) {
  path <- normalizePath(path, mustWork = TRUE)
  if (!dir.exists(path)) {
    stop(label, " is not a directory: ", path)
  }
  path
}

git_output <- function(project, ...) {
  # Git's stderr stays on the console so warnings never reach parsed output.
  output <- system2("git", c("-C", shQuote(project), ...), stdout = TRUE)
  status <- attr(output, "status")
  if (!is.null(status) && status != 0L) {
    stop("git failed in ", project, " with exit status ", status, ".")
  }
  output
}

git_root <- function(project) {
  normalize_directory(
    git_output(project, "rev-parse", "--show-toplevel")[[1L]],
    "Git root"
  )
}

git_path <- function(project, path) {
  output <- git_output(
    project,
    "rev-parse",
    "--path-format=absolute",
    "--git-path",
    shQuote(path)
  )
  output[[1L]]
}

safe_relative_path <- function(path, label = "Path") {
  if (
    !is.character(path) ||
      length(path) != 1L ||
      is.na(path) ||
      !nzchar(path) ||
      startsWith(path, "/")
  ) {
    stop(label, " must be one non-empty relative path.")
  }
  components <- strsplit(path, "/", fixed = TRUE)[[1L]]
  if (any(!nzchar(components)) || any(components %in% c(".", ".."))) {
    stop(label, " must be normalized and cannot contain . or .. components.")
  }
  path
}

safe_destination <- function(root, relative, label = "Destination") {
  root <- normalize_directory(root, "Destination root")
  relative <- safe_relative_path(relative, label)
  destination <- file.path(root, relative)
  ancestor <- dirname(destination)
  while (!occupied(ancestor)) {
    parent <- dirname(ancestor)
    if (identical(parent, ancestor)) {
      stop(label, " has no resolvable parent: ", destination)
    }
    ancestor <- parent
  }
  resolved_ancestor <- normalizePath(ancestor, mustWork = TRUE)
  if (
    !identical(resolved_ancestor, root) &&
      !startsWith(resolved_ancestor, paste0(root, "/"))
  ) {
    stop(label, " escapes its root through an existing ancestor: ", destination)
  }
  destination
}

configured_store <- function(project) {
  project <- git_root(project)
  store <- withr::with_dir(project, targets::tar_config_get("store"))
  safe_relative_path(store, "Configured targets store")
}

state_path <- function(project) {
  git_path(project, "targets-worktree/state.rds")
}

receipt_directory <- function(project) {
  git_path(project, "targets-worktree/receipts")
}

read_state <- function(project, required = TRUE) {
  path <- state_path(project)
  if (!file.exists(path)) {
    if (required) {
      stop("No targets-worktree state exists for: ", project)
    }
    return(NULL)
  }
  state <- readRDS(path)
  if (!identical(state$schema_version, 1L)) {
    stop("Unsupported targets-worktree state schema.")
  }
  state$store_relative <- safe_relative_path(
    state$store_relative,
    "Recorded targets store"
  )
  if (!identical(normalizePath(state$project, mustWork = TRUE), git_root(project))) {
    stop("State belongs to a different worktree.")
  }
  state
}

write_state <- function(state) {
  path <- state_path(state$project)
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  temporary <- tempfile(".state-", tmpdir = dirname(path))
  saveRDS(state, temporary)
  if (!file.rename(temporary, path)) {
    unlink(temporary)
    stop("Could not atomically save worktree state.")
  }
  invisible(state)
}

remove_state <- function(state) {
  path <- state_path(state$project)
  receipts <- receipt_directory(state$project)
  dir.create(receipts, recursive = TRUE, showWarnings = FALSE)
  receipt <- file.path(
    receipts,
    paste0(format(Sys.time(), "%Y%m%dT%H%M%S"), "-", state$id, ".rds")
  )
  state$phase <- "removed"
  state$removed_at <- format(Sys.time(), tz = "UTC", usetz = TRUE)
  saveRDS(state, receipt)
  if (unlink(path) != 0L) {
    stop("Could not remove active state after saving teardown receipt.")
  }
  invisible(receipt)
}

same_path <- function(path, expected) {
  identical(
    normalizePath(path, mustWork = TRUE),
    normalizePath(expected, mustWork = TRUE)
  )
}

link_value <- function(path) {
  value <- Sys.readlink(path)
  if (is.na(value) || !nzchar(value)) NA_character_ else value
}

occupied <- function(path) {
  file.exists(path) || !is.na(link_value(path))
}

# A symlink matches when its text is the recorded source, so a managed link
# stays recognizable after its source disappears, such as an expired snapshot.
# Resolved equality also accepts adopted links and pre-0.1.2 link text.
link_matches <- function(path, source) {
  current <- link_value(path)
  !is.na(current) &&
    (identical(current, source) ||
      (file.exists(path) && file.exists(source) && same_path(path, source)))
}

ensure_link <- function(destination, source) {
  if (!is.na(link_value(destination))) {
    if (!link_matches(destination, source)) {
      stop("Conflicting symlink: ", destination)
    }
    return(FALSE)
  }
  if (file.exists(destination)) {
    stop("Conflicting existing path: ", destination)
  }
  if (!file.exists(source)) {
    stop("Symlink source does not exist: ", source)
  }
  dir.create(dirname(destination), recursive = TRUE, showWarnings = FALSE)
  if (!file.symlink(source, destination)) {
    stop("Could not create symlink: ", destination)
  }
  TRUE
}

remove_exact_link <- function(destination, source) {
  if (is.na(link_value(destination))) {
    stop("Expected a managed symlink: ", destination)
  }
  if (!link_matches(destination, source)) {
    stop("Managed symlink no longer points to its recorded source: ", destination)
  }
  if (unlink(destination) != 0L) {
    stop("Could not unlink managed path: ", destination)
  }
  invisible(destination)
}

validate_project_pair <- function(project, base) {
  project <- git_root(project)
  base <- git_root(base)
  if (identical(project, base)) {
    stop("Refusing to configure the base checkout itself.")
  }
  project_common <- normalizePath(
    git_output(
      project,
      "rev-parse",
      "--path-format=absolute",
      "--git-common-dir"
    )[[1L]],
    mustWork = TRUE
  )
  base_common <- normalizePath(
    git_output(
      base,
      "rev-parse",
      "--path-format=absolute",
      "--git-common-dir"
    )[[1L]],
    mustWork = TRUE
  )
  if (!identical(project_common, base_common)) {
    stop("Project and base must be worktrees of the same Git repository.")
  }
  list(project = project, base = base)
}

validate_runtime_links <- function(runtime_links) {
  if (length(runtime_links) == 0L) {
    return(data.frame(
      relative = character(),
      source = character(),
      managed = logical()
    ))
  }
  if (is.null(names(runtime_links)) || any(!nzchar(names(runtime_links)))) {
    stop("Runtime links must be a named character vector of relative path = source.")
  }
  relative <- vapply(
    names(runtime_links),
    safe_relative_path,
    character(1),
    label = "Runtime link path"
  )
  source <- vapply(
    runtime_links,
    normalizePath,
    character(1),
    mustWork = TRUE
  )
  data.frame(
    relative = relative,
    source = source,
    managed = FALSE,
    stringsAsFactors = FALSE
  )
}

# Immutable source discovery and selective-store planning --------------------

latest_snapshot <- function(base_store, snapshot_pattern = NULL) {
  snapshot_root <- file.path(base_store, ".snapshot")
  if (!dir.exists(snapshot_root)) {
    stop("No snapshot directory exists under the base store: ", snapshot_root)
  }
  if (!is.null(snapshot_pattern)) {
    if (
      !is.character(snapshot_pattern) ||
        length(snapshot_pattern) != 1L ||
        is.na(snapshot_pattern) ||
        !nzchar(snapshot_pattern)
    ) {
      stop("Snapshot pattern must be one non-empty regular expression.")
    }
    tryCatch(
      suppressWarnings(grepl(snapshot_pattern, "", perl = TRUE)),
      error = function(error) {
        stop("Invalid snapshot pattern: ", conditionMessage(error))
      }
    )
  }

  for (attempt in seq_len(3L)) {
    candidates <- list.dirs(snapshot_root, recursive = FALSE, full.names = TRUE)
    if (!is.null(snapshot_pattern)) {
      candidates <- candidates[
        grepl(snapshot_pattern, basename(candidates), perl = TRUE)
      ]
    }
    candidates <- candidates[
      file.exists(file.path(candidates, "meta", "meta"))
    ]
    if (length(candidates) > 0L || attempt == 3L) {
      break
    }
    Sys.sleep(0.2 * attempt)
  }
  if (length(candidates) == 0L) {
    qualifier <- if (is.null(snapshot_pattern)) {
      ""
    } else {
      paste0(" matching pattern ", shQuote(snapshot_pattern))
    }
    stop(
      "No complete targets-store snapshot", qualifier,
      " was found under: ", snapshot_root
    )
  }
  candidates <- sort(candidates)
  normalizePath(candidates[[length(candidates)]], mustWork = TRUE)
}

resolve_source <- function(
  base,
  store_relative,
  source = NULL,
  snapshot_pattern = NULL
) {
  base_store <- file.path(base, store_relative)
  if (!is.null(source) && !is.null(snapshot_pattern)) {
    stop("Use either an explicit source or a snapshot pattern, not both.")
  }
  source <- if (is.null(source)) {
    latest_snapshot(base_store, snapshot_pattern)
  } else {
    source
  }
  source <- normalize_directory(source, "Immutable targets-store source")
  if (!file.exists(file.path(source, "meta", "meta"))) {
    stop("Targets metadata is missing from source: ", source)
  }
  if (dir.exists(base_store) && same_path(source, base_store)) {
    stop("The live base targets store cannot be used as a source.")
  }
  snapshot_root <- file.path(base_store, ".snapshot")
  snapshot_path <- dir.exists(snapshot_root) &&
    startsWith(
      source,
      paste0(normalizePath(snapshot_root, mustWork = TRUE), "/")
    )
  permissions_read_only <- file.access(
    file.path(source, "meta", "meta"),
    mode = 2L
  ) != 0L
  if (!snapshot_path && !permissions_read_only) {
    stop(
      "Source is not demonstrably immutable. Use a filesystem snapshot ",
      "or remove write permission."
    )
  }
  source
}

target_graph <- function(project, target_names) {
  withr::with_dir(project, {
    targets::tar_network(
      targets_only = TRUE,
      names = tidyselect::all_of(target_names),
      outdated = FALSE,
      reporter = "silent"
    )
  })
}

target_outdated <- function(project, target_names) {
  withr::with_dir(project, {
    targets::tar_outdated(
      names = tidyselect::all_of(target_names),
      reporter = "silent"
    )
  })
}

expand_file_rows <- function(metadata) {
  indices <- which(metadata$format == "file")
  rows <- lapply(indices, function(index) {
    paths <- metadata$path[[index]]
    paths <- paths[!is.na(paths) & nzchar(paths)]
    if (length(paths) == 0L) {
      return(NULL)
    }
    data.frame(
      name = metadata$name[[index]],
      parent = metadata$parent[[index]],
      path = paths,
      stringsAsFactors = FALSE
    )
  })
  rows <- rows[!vapply(rows, is.null, logical(1))]
  if (length(rows) == 0L) {
    return(data.frame(
      name = character(),
      parent = character(),
      path = character(),
      stringsAsFactors = FALSE
    ))
  }
  do.call(rbind, rows)
}

plan_snapshot <- function(project, target_names, source) {
  store_relative <- configured_store(project)
  store <- safe_destination(project, store_relative, "Configured targets store")
  if (!link_matches(store, source)) {
    stop("Snapshot planning requires the configured store to link to the source.")
  }

  graph <- target_graph(project, target_names)
  closure_names <- unique(graph$vertices$name)
  outdated_names <- target_outdated(project, target_names)
  ready_names <- setdiff(closure_names, outdated_names)
  metadata <- targets::tar_meta(
    store = store,
    fields = tidyselect::everything()
  )
  ready <- metadata[
    metadata$name %in% ready_names |
      (!is.na(metadata$parent) & metadata$parent %in% ready_names),
    ,
    drop = FALSE
  ]
  ready <- ready[
    ready$type != "pattern" & is.na(ready$error),
    ,
    drop = FALSE
  ]

  objects <- ready[
    ready$format != "file",
    c("name", "parent"),
    drop = FALSE
  ]
  objects$relative <- file.path("objects", objects$name)
  objects$source <- file.path(source, objects$relative)
  objects$kind <- rep("object", nrow(objects))

  files <- expand_file_rows(ready)
  if (nrow(files) > 0L) {
    store_prefix <- paste0(store_relative, "/")
    files$class <- ifelse(
      startsWith(files$path, "/"),
      "external",
      ifelse(startsWith(files$path, store_prefix), "store", "project")
    )
    files$relative <- ifelse(
      files$class == "store",
      substring(files$path, nchar(store_prefix) + 1L),
      NA_character_
    )
    files$source <- ifelse(
      files$class == "store",
      file.path(source, files$relative),
      ifelse(
        files$class == "external",
        files$path,
        file.path(project, files$path)
      )
    )
    store_indices <- which(files$class == "store")
    files$relative[store_indices] <- vapply(
      files$relative[store_indices],
      safe_relative_path,
      character(1),
      label = "Store-relative file target"
    )
    project_indices <- which(files$class == "project")
    files$path[project_indices] <- vapply(
      files$path[project_indices],
      safe_relative_path,
      character(1),
      label = "Project-relative file target"
    )
  } else {
    files$class <- character()
    files$relative <- character()
    files$source <- character()
  }

  linked_files <- files[files$class == "store", , drop = FALSE]
  linked_files$kind <- rep("file", nrow(linked_files))
  required_files <- files[files$class != "store", , drop = FALSE]
  missing <- c(
    objects$source[!file.exists(objects$source)],
    linked_files$source[
      !file.exists(linked_files$source) & !dir.exists(linked_files$source)
    ],
    required_files$source[
      !file.exists(required_files$source) & !dir.exists(required_files$source)
    ]
  )
  if (length(missing) > 0L) {
    stop(
      "Ready target outputs or inputs are missing:\n",
      paste(unique(missing), collapse = "\n")
    )
  }

  links <- rbind(
    objects[, c("name", "parent", "relative", "source", "kind")],
    linked_files[, c("name", "parent", "relative", "source", "kind")]
  )
  rownames(links) <- NULL
  list(
    closure = closure_names,
    outdated = outdated_names,
    links = links
  )
}

materialize_plan <- function(project, store_relative, source, plan, stage) {
  store <- safe_destination(project, store_relative, "Configured targets store")
  if (!link_matches(store, source)) {
    stop("Planning symlink changed before materialization.")
  }
  if (unlink(store) != 0L) {
    stop("Could not remove planning symlink.")
  }

  if (occupied(stage)) {
    stop("Staging path already exists: ", stage)
  }
  dir.create(file.path(stage, "meta"), recursive = TRUE)
  dir.create(file.path(stage, "objects"), recursive = TRUE)
  incomplete <- TRUE
  on.exit({
    if (incomplete && dir.exists(stage)) {
      unlink(stage, recursive = TRUE)
    }
  }, add = TRUE)

  metadata_source <- file.path(source, "meta", "meta")
  metadata_destination <- file.path(stage, "meta", "meta")
  if (!file.copy(metadata_source, metadata_destination, overwrite = FALSE)) {
    stop("Could not copy targets metadata into scratch.")
  }
  Sys.chmod(metadata_destination, "0644", use_umask = FALSE)
  if (file.access(metadata_destination, 2L) != 0L) {
    stop("Scratch metadata is not writable.")
  }

  for (index in seq_len(nrow(plan$links))) {
    destination <- safe_destination(
      stage,
      plan$links$relative[[index]],
      "Selective-store link"
    )
    ensure_link(destination, plan$links$source[[index]])
  }
  if (!file.rename(stage, store)) {
    stop("Could not atomically install selective targets store.")
  }
  incomplete <- FALSE
  invisible(store)
}

# Lifecycle, reconciliation, execution, and teardown -------------------------

create_id <- function() {
  paste0(
    format(Sys.time(), "%Y%m%dT%H%M%S"),
    "-",
    Sys.getpid(),
    "-",
    sprintf("%06d", sample.int(999999L, 1L))
  )
}

configure <- function(
  project,
  base,
  source = NULL,
  snapshot_pattern = NULL,
  runtime_links = character()
) {
  pair <- validate_project_pair(project, base)
  project <- pair$project
  base <- pair$base

  store_relative <- configured_store(project)
  base_store_relative <- configured_store(base)
  if (!identical(store_relative, base_store_relative)) {
    stop("Base and worktree configure different targets stores.")
  }
  store <- safe_destination(project, store_relative, "Configured targets store")
  runtime <- validate_runtime_links(runtime_links)
  existing <- read_state(project, required = FALSE)
  if (!is.null(existing)) {
    stop(
      "Worktree is already configured in ", existing$mode,
      " mode. Teardown before reconfiguration."
    )
  }
  if (occupied(store)) {
    stop("Configured targets-store path already exists: ", store)
  }

  # A worktree with its own environment keeps it. Otherwise it links the base
  # environment, which is only safe while both checkouts lock the same
  # packages: Pixi would rewrite the shared environment to match the worktree.
  pixi_source <- normalizePath(file.path(base, ".pixi"), mustWork = FALSE)
  pixi_destination <- file.path(project, ".pixi")
  own_pixi <- dir.exists(pixi_destination) && is.na(link_value(pixi_destination))
  link_pixi <- dir.exists(pixi_source) && !own_pixi
  if (link_pixi) {
    if (occupied(pixi_destination) && !link_matches(pixi_destination, pixi_source)) {
      stop("Conflicting worktree .pixi path.")
    }
    locks <- file.path(c(base, project), "pixi.lock")
    if (all(file.exists(locks)) && length(unique(tools::md5sum(locks))) != 1L) {
      stop(
        "The worktree pixi.lock differs from the base, so Pixi could rewrite ",
        "the linked base environment. Align the lock files, or run ",
        "`pixi install` in the worktree to give it its own environment."
      )
    }
  }
  for (index in seq_len(nrow(runtime))) {
    destination <- safe_destination(
      project,
      runtime$relative[[index]],
      "Runtime link path"
    )
    if (occupied(destination) && !link_matches(destination, runtime$source[[index]])) {
      stop("Conflicting runtime path: ", destination)
    }
  }

  source_path <- resolve_source(
    base,
    store_relative,
    source,
    snapshot_pattern
  )
  state <- list(
    schema_version = 1L,
    id = create_id(),
    phase = "preparing",
    created_at = format(Sys.time(), tz = "UTC", usetz = TRUE),
    project = project,
    base = base,
    mode = "read-only",
    store_relative = store_relative,
    source = source_path,
    snapshot_pattern = snapshot_pattern,
    targets = character(),
    closure = character(),
    outdated = character(),
    links = data.frame(),
    pixi = list(
      source = if (link_pixi) pixi_source else NULL,
      managed = FALSE
    ),
    runtime_links = runtime,
    stage = NULL,
    quarantine = NULL
  )
  write_state(state)

  rollback <- TRUE
  on.exit({
    if (rollback) {
      current <- read_state(project, required = FALSE)
      if (!is.null(current)) {
        try(teardown(project, recovering = TRUE), silent = TRUE)
      }
    }
  }, add = TRUE)

  if (link_pixi) {
    state$pixi$managed <- ensure_link(pixi_destination, pixi_source)
    write_state(state)
  }
  for (index in seq_len(nrow(runtime))) {
    runtime$managed[[index]] <- ensure_link(
      safe_destination(
        project,
        runtime$relative[[index]],
        "Runtime link path"
      ),
      runtime$source[[index]]
    )
    state$runtime_links <- runtime
    write_state(state)
  }

  ensure_link(store, source_path)

  state$phase <- "ready"
  write_state(state)
  rollback <- FALSE
  status(project)
}

rollback_conversion <- function(project) {
  state <- read_state(project)
  store <- safe_destination(
    state$project,
    state$store_relative,
    "Recorded targets store"
  )

  if (!is.null(state$stage) && occupied(state$stage)) {
    if (!dir.exists(state$stage) || !is.na(link_value(state$stage))) {
      stop("Failed conversion left an unexpected staging path: ", state$stage)
    }
    state$quarantine <- c(
      state$quarantine,
      quarantine_path(state, state$stage, "failed-conversion-stage")
    )
  }

  if (!is.na(link_value(store))) {
    if (!link_matches(store, state$source)) {
      stop("Failed conversion left an unexpected targets-store symlink: ", store)
    }
  } else if (dir.exists(store)) {
    state$quarantine <- c(
      state$quarantine,
      quarantine_path(state, store, "failed-conversion")
    )
    ensure_link(store, state$source)
  } else if (file.exists(store)) {
    stop("Failed conversion left an unexpected targets-store file: ", store)
  } else {
    ensure_link(store, state$source)
  }

  state$mode <- "read-only"
  state$phase <- "ready"
  state$targets <- character()
  state$closure <- character()
  state$outdated <- character()
  state$links <- data.frame()
  state$stage <- NULL
  write_state(state)
  invisible(state)
}

convert <- function(project, target_names) {
  state <- read_state(project)
  if (!identical(state$phase, "ready") ||
    !identical(state$mode, "read-only")) {
    stop("Conversion requires a ready read-only worktree.")
  }
  target_names <- unique(target_names[nzchar(target_names)])
  if (length(target_names) == 0L) {
    stop("Conversion requires at least one endpoint target.")
  }

  store <- safe_destination(
    state$project,
    state$store_relative,
    "Recorded targets store"
  )
  if (!link_matches(store, state$source)) {
    stop("Read-only store no longer links to its recorded source.")
  }
  require_source(state)

  # Planning is read-only. A planning failure therefore leaves the original
  # worktree state and store link untouched.
  plan <- plan_snapshot(state$project, target_names, state$source)
  stage <- file.path(
    dirname(store),
    paste0(".", basename(store), ".targets-worktree-stage-", state$id)
  )
  if (occupied(stage)) {
    stop("Conversion staging path already exists: ", stage)
  }

  state$mode <- "writable-selective"
  state$phase <- "converting"
  state$targets <- target_names
  state$stage <- stage
  write_state(state)

  rollback <- TRUE
  on.exit({
    if (rollback) {
      recovery_error <- tryCatch(
        {
          rollback_conversion(state$project)
          NULL
        },
        error = identity
      )
      if (!is.null(recovery_error)) {
        warning(
          "Automatic conversion rollback failed; run teardown to recover: ",
          conditionMessage(recovery_error),
          call. = FALSE
        )
      }
    }
  }, add = TRUE)

  materialize_plan(
    state$project,
    state$store_relative,
    state$source,
    plan,
    stage
  )
  state$stage <- NULL
  state$closure <- plan$closure
  state$outdated <- plan$outdated
  state$links <- plan$links
  state$phase <- "ready"
  state$converted_at <- format(Sys.time(), tz = "UTC", usetz = TRUE)
  write_state(state)
  rollback <- FALSE
  status(state$project)
}

require_source <- function(state) {
  if (!dir.exists(state$source)) {
    stop(
      "The recorded source no longer exists: ", state$source,
      "\nIts snapshot may have expired. Teardown and configure again."
    )
  }
}

owner_outdated <- function(links, outdated) {
  links$name %in% outdated |
    (!is.na(links$parent) & links$parent %in% outdated)
}

active_targets_process <- function(store) {
  pid <- tryCatch(targets::tar_pid(store = store), error = function(error) NA_integer_)
  if (length(pid) != 1L || is.na(pid) || pid <= 0L) {
    return(FALSE)
  }
  if (identical(as.integer(pid), as.integer(Sys.getpid()))) {
    return(FALSE)
  }
  status <- suppressWarnings(
    system2("kill", c("-0", as.character(pid)), stdout = FALSE, stderr = FALSE)
  )
  identical(status, 0L)
}

reconcile <- function(project, target_names = NULL) {
  state <- read_state(project)
  if (!identical(state$phase, "ready") ||
    !identical(state$mode, "writable-selective")) {
    stop("Reconciliation requires a ready writable-selective worktree.")
  }
  store <- safe_destination(
    state$project,
    state$store_relative,
    "Recorded targets store"
  )
  if (!dir.exists(store) || !is.na(link_value(store))) {
    stop("Selective store is not a physical directory.")
  }
  if (active_targets_process(store)) {
    stop("A targets process is already active in this worktree.")
  }

  target_names <- if (is.null(target_names)) state$targets else unique(target_names)
  if (!all(target_names %in% state$targets)) {
    stop(
      "Run targets must be a subset of configured endpoints. ",
      "Reconfigure to expand the selective store."
    )
  }
  outdated <- if (nrow(state$links) == 0L) {
    character()
  } else {
    require_source(state)
    target_outdated(state$project, target_names)
  }
  remove <- owner_outdated(state$links, outdated)
  retained <- rep(TRUE, nrow(state$links))

  for (index in seq_len(nrow(state$links))) {
    destination <- safe_destination(
      store,
      state$links$relative[[index]],
      "Managed selective-store link"
    )
    source <- state$links$source[[index]]
    current <- link_value(destination)
    if (remove[[index]]) {
      if (!is.na(current)) {
        remove_exact_link(destination, source)
      } else if (file.exists(destination)) {
        retained[[index]] <- FALSE
      }
    } else if (!is.na(current)) {
      if (!link_matches(destination, source)) {
        stop("Managed link points to an unexpected source: ", destination)
      }
    } else if (file.exists(destination)) {
      retained[[index]] <- FALSE
    } else {
      ensure_link(destination, source)
    }
  }

  state$links <- state$links[retained & !remove, , drop = FALSE]
  state$outdated <- outdated
  state$reconciled_at <- format(Sys.time(), tz = "UTC", usetz = TRUE)
  write_state(state)
  list(state = state, targets = target_names, outdated = outdated)
}

run <- function(project, target_names = NULL, local = FALSE) {
  reconciliation <- reconcile(project, target_names)
  withr::with_dir(reconciliation$state$project, {
    if (local) {
      previous_controller <- targets::tar_option_get("controller")
      on.exit(
        targets::tar_option_set(controller = previous_controller),
        add = TRUE
      )
      targets::tar_option_set(
        controller = crew::crew_controller_local(workers = 1L)
      )
      targets::tar_make(
        names = tidyselect::all_of(reconciliation$targets),
        callr_function = NULL,
        envir = globalenv()
      )
    } else {
      targets::tar_make(
        names = tidyselect::all_of(reconciliation$targets)
      )
    }
  })
  state <- read_state(project)
  if (setequal(reconciliation$targets, state$targets)) {
    state$outdated <- character()
  }
  state$last_run_targets <- reconciliation$targets
  state$last_run_at <- format(Sys.time(), tz = "UTC", usetz = TRUE)
  write_state(state)
  invisible(status(project))
}

quarantine_path <- function(state, path, suffix = NULL) {
  root <- file.path(dirname(state$project), ".targets-worktree-quarantine")
  dir.create(root, recursive = TRUE, showWarnings = FALSE)
  destination <- file.path(
    root,
    paste0(
      basename(state$project),
      "-",
      state$id,
      if (is.null(suffix)) "" else paste0("-", suffix)
    )
  )
  if (occupied(destination)) {
    stop("Quarantine destination already exists: ", destination)
  }
  if (!file.rename(path, destination)) {
    stop("Could not move writable store to quarantine: ", destination)
  }
  destination
}

teardown <- function(project, recovering = FALSE) {
  state <- read_state(project)
  store <- safe_destination(
    state$project,
    state$store_relative,
    "Recorded targets store"
  )
  if (!is.null(state$stage)) {
    expected_stage <- file.path(
      dirname(store),
      paste0(
        ".",
        basename(store),
        ".targets-worktree-stage-",
        state$id
      )
    )
    if (!identical(state$stage, expected_stage)) {
      stop("Recorded staging path does not match its worktree state.")
    }
  }
  state$phase <- "removing"
  write_state(state)

  if (!is.null(state$stage) && occupied(state$stage)) {
    if (!dir.exists(state$stage) || !is.na(link_value(state$stage))) {
      stop("Recorded staging path is not a physical directory: ", state$stage)
    }
    state$quarantine <- c(
      state$quarantine,
      quarantine_path(state, state$stage, "incomplete")
    )
    state$stage <- NULL
    write_state(state)
  }

  if (
    identical(state$mode, "writable-selective") &&
      link_matches(store, state$source)
  ) {
    remove_exact_link(store, state$source)
  } else if (identical(state$mode, "read-only") && occupied(store)) {
    remove_exact_link(store, state$source)
  } else if (
    identical(state$mode, "writable-selective") &&
      dir.exists(store) &&
      is.na(link_value(store))
  ) {
    if (!recovering && active_targets_process(store)) {
      state$phase <- "ready"
      write_state(state)
      stop("A targets process is active; refusing teardown.")
    }
    state$quarantine <- c(
      state$quarantine,
      quarantine_path(state, store)
    )
    write_state(state)
  } else if (occupied(store)) {
    stop("Targets-store path does not match recorded mode: ", store)
  }

  runtime <- state$runtime_links
  if (nrow(runtime) > 0L) {
    for (index in rev(seq_len(nrow(runtime)))) {
      if (isTRUE(runtime$managed[[index]])) {
        destination <- safe_destination(
          state$project,
          runtime$relative[[index]],
          "Recorded runtime link"
        )
        remove_exact_link(
          destination,
          runtime$source[[index]]
        )
      }
    }
  }
  if (isTRUE(state$pixi$managed)) {
    remove_exact_link(
      safe_destination(state$project, ".pixi", "Recorded Pixi link"),
      state$pixi$source
    )
  }
  receipt <- remove_state(state)
  list(
    project = state$project,
    mode = state$mode,
    quarantine = state$quarantine,
    receipt = receipt
  )
}

status <- function(project) {
  state <- read_state(project)
  store <- safe_destination(
    state$project,
    state$store_relative,
    "Recorded targets store"
  )
  list(
    project = state$project,
    base = state$base,
    mode = state$mode,
    phase = state$phase,
    store = store,
    source = state$source,
    source_missing = !dir.exists(state$source),
    snapshot_pattern = state$snapshot_pattern,
    targets = state$targets,
    closure_targets = length(state$closure),
    outdated_targets = length(state$outdated),
    managed_links = nrow(state$links),
    quarantine = state$quarantine
  )
}
