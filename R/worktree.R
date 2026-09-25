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
  # Name order is only chronological within one naming family, so refuse to
  # guess between families; a short-lived replication snapshot could win.
  families <- unique(gsub("[0-9]+", "#", basename(candidates)))
  if (is.null(snapshot_pattern) && length(families) > 1L) {
    stop(
      "Snapshots from several naming families exist under ", snapshot_root,
      ":\n", paste(families, collapse = "\n"),
      "\nChoose one with --snapshot-pattern."
    )
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

# A snapshot value is reusable wherever the worktree metadata row is still the
# row copied from the snapshot. Linking such values before targets checks the
# closure lets targets decide outdatedness against the current worktree code.
snapshot_links <- function(state, store, target_names) {
  closure <- unique(target_graph(state$project, target_names)$vertices$name)
  meta_fields <- c("name", "type", "format", "path", "parent", "data", "error")
  source_meta <- targets::tar_meta(
    store = state$source,
    fields = tidyselect::all_of(meta_fields)
  )
  worktree_meta <- targets::tar_meta(
    store = store,
    fields = tidyselect::all_of(meta_fields)
  )
  rows <- source_meta[
    (source_meta$name %in% closure | source_meta$parent %in% closure) &
      source_meta$type != "pattern" &
      is.na(source_meta$error) &
      paste(source_meta$name, source_meta$data) %in%
        paste(worktree_meta$name, worktree_meta$data),
    ,
    drop = FALSE
  ]

  objects <- rows[rows$format != "file", c("name", "parent"), drop = FALSE]
  objects$relative <- file.path("objects", objects$name)
  objects$kind <- rep("object", nrow(objects))

  # Only store-relative file targets live in the store; others stay in place.
  files <- expand_file_rows(rows)
  store_prefix <- paste0(state$store_relative, "/")
  files <- files[startsWith(files$path, store_prefix), , drop = FALSE]
  files$relative <- unname(vapply(
    substring(files$path, nchar(store_prefix) + 1L),
    safe_relative_path,
    character(1),
    label = "Store-relative file target"
  ))
  files$kind <- rep("file", nrow(files))

  links <- rbind(objects, files[, names(objects), drop = FALSE])
  links$source <- file.path(state$source, links$relative)
  rownames(links) <- NULL
  list(closure = closure, links = links)
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

convert_store <- function(state) {
  store <- safe_destination(
    state$project,
    state$store_relative,
    "Recorded targets store"
  )
  if (!link_matches(store, state$source)) {
    stop("Read-only store no longer links to its recorded source.")
  }
  stage <- file.path(
    dirname(store),
    paste0(".", basename(store), ".targets-worktree-stage-", state$id)
  )
  if (occupied(stage)) {
    stop("Conversion staging path already exists: ", stage)
  }

  state$mode <- "writable-selective"
  state$phase <- "converting"
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

  dir.create(file.path(stage, "meta"), recursive = TRUE)
  dir.create(file.path(stage, "objects"))
  metadata <- file.path(stage, "meta", "meta")
  if (!file.copy(file.path(state$source, "meta", "meta"), metadata)) {
    stop("Could not copy targets metadata into scratch.")
  }
  Sys.chmod(metadata, "0644", use_umask = FALSE)
  if (unlink(store) != 0L || !file.rename(stage, store)) {
    stop("Could not atomically install the writable targets store.")
  }
  state$stage <- NULL
  state$phase <- "ready"
  state$converted_at <- format(Sys.time(), tz = "UTC", usetz = TRUE)
  write_state(state)
  rollback <- FALSE
  state
}

# Values the worktree built itself are never replaced by links.
link_values <- function(state, plan) {
  store <- safe_destination(
    state$project,
    state$store_relative,
    "Recorded targets store"
  )
  linked <- vapply(seq_len(nrow(plan$links)), function(index) {
    destination <- safe_destination(
      store,
      plan$links$relative[[index]],
      "Snapshot value link"
    )
    if (file.exists(destination) && is.na(link_value(destination))) {
      return(FALSE)
    }
    ensure_link(destination, plan$links$source[[index]])
    TRUE
  }, logical(1))
  state$links <- unique(rbind(state$links, plan$links[linked, , drop = FALSE]))
  state$closure <- union(state$closure, plan$closure)
  write_state(state)
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

reconcile <- function(state, target_names) {
  store <- safe_destination(
    state$project,
    state$store_relative,
    "Recorded targets store"
  )
  if (!dir.exists(store) || !is.na(link_value(store))) {
    stop("Writable store is not a physical directory.")
  }
  outdated <- if (nrow(state$links) == 0L) {
    character()
  } else {
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
}

run <- function(project, target_names, local = FALSE) {
  state <- read_state(project)
  if (!identical(state$phase, "ready")) {
    stop("Runs require a ready worktree; teardown to recover from: ", state$phase)
  }
  target_names <- unique(target_names[nzchar(target_names)])
  if (length(target_names) == 0L) {
    stop("Runs require at least one target.")
  }
  require_source(state)
  store <- safe_destination(
    state$project,
    state$store_relative,
    "Recorded targets store"
  )
  if (identical(state$mode, "writable-selective") && active_targets_process(store)) {
    stop("A targets process is already active in this worktree.")
  }

  # Planning only reads, so an unknown target or a broken pipeline leaves the
  # worktree unchanged. The first run converts the read-only store.
  plan <- snapshot_links(state, store, target_names)
  if (identical(state$mode, "read-only")) {
    state <- convert_store(state)
  }
  state <- reconcile(link_values(state, plan), target_names)

  withr::with_dir(state$project, {
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
        names = tidyselect::all_of(target_names),
        callr_function = NULL,
        envir = globalenv()
      )
    } else {
      targets::tar_make(names = tidyselect::all_of(target_names))
    }
  })
  state <- read_state(project)
  state$targets <- union(state$targets, target_names)
  state$outdated <- character()
  state$last_run_targets <- target_names
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
    if (
      occupied(state$stage) &&
        (!dir.exists(state$stage) || !is.na(link_value(state$stage)))
    ) {
      stop("Recorded staging path is not a physical directory: ", state$stage)
    }
  }

  # Validate every recorded path before the first change, so a refusal leaves
  # the worktree ready. Recorded paths that are already gone are skipped, which
  # lets an interrupted teardown resume.
  selective <- identical(state$mode, "writable-selective")
  store_link <- link_matches(store, state$source)
  store_physical <- selective && dir.exists(store) && is.na(link_value(store))
  if (occupied(store) && !store_link && !store_physical) {
    stop("Targets-store path does not match recorded mode: ", store)
  }
  if (store_physical && !recovering && active_targets_process(store)) {
    stop("A targets process is active; refusing teardown.")
  }
  runtime <- state$runtime_links
  links <- runtime[runtime$managed %in% TRUE, c("relative", "source"), drop = FALSE]
  if (isTRUE(state$pixi$managed)) {
    links <- rbind(links, data.frame(relative = ".pixi", source = state$pixi$source))
  }
  links$destination <- vapply(
    links$relative,
    safe_destination,
    character(1),
    root = state$project,
    label = "Recorded link"
  )
  for (index in seq_len(nrow(links))) {
    if (occupied(links$destination[[index]]) &&
      !link_matches(links$destination[[index]], links$source[[index]])) {
      stop(
        "Managed symlink no longer points to its recorded source: ",
        links$destination[[index]]
      )
    }
  }

  state$phase <- "removing"
  write_state(state)
  if (!is.null(state$stage) && occupied(state$stage)) {
    state$quarantine <- c(
      state$quarantine,
      quarantine_path(state, state$stage, "incomplete")
    )
    state$stage <- NULL
    write_state(state)
  }
  if (store_link) {
    remove_exact_link(store, state$source)
  } else if (store_physical) {
    state$quarantine <- c(state$quarantine, quarantine_path(state, store))
    write_state(state)
  }
  for (index in rev(seq_len(nrow(links)))) {
    if (occupied(links$destination[[index]])) {
      remove_exact_link(links$destination[[index]], links$source[[index]])
    }
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
