read_state <- getFromNamespace("read_state", "targetsworktree")
worktree_locked <- getFromNamespace("worktree_locked", "targetsworktree")
Sys.unsetenv(c("R_PROFILE_USER", "R_TESTS"))

run <- function(command) {
  output <- system2(
    command[[1L]],
    vapply(command[-1L], shQuote, character(1)),
    stdout = TRUE,
    stderr = TRUE
  )
  status <- attr(output, "status")
  if (!is.null(status) && status != 0L) {
    stop(paste(output, collapse = "\n"))
  }
  output
}

is_link <- function(path) {
  value <- Sys.readlink(path)
  !is.na(value) && nzchar(value)
}

test_root <- tempfile("targets-worktree-integration-")
dir.create(test_root)
withr::defer(
  system2("chmod", c("-R", "u+w", test_root), stdout = FALSE, stderr = FALSE),
  envir = globalenv()
)
base <- file.path(test_root, "base")
worktree <- file.path(test_root, "worktree")
store <- file.path(worktree, "pipeline", "outputs")
dir.create(base)

invisible(run(c("git", "init", "-b", "main", base)))
invisible(run(c("git", "-C", base, "config", "user.name", "targets-worktree test")))
invisible(run(c(
  "git", "-C", base, "config", "user.email",
  "targets-worktree@example.invalid"
)))
writeLines("pipeline/outputs", file.path(base, ".gitignore"))
writeLines(
  c(
    "main:",
    "  script: _targets.R",
    "  store: pipeline/outputs"
  ),
  file.path(base, "_targets.yaml")
)
writeLines(
  paste(
    "if (!file.exists('pipeline/outputs') &&",
    "!dir.exists('pipeline/outputs'))",
    "dir.create('pipeline/outputs', recursive = TRUE)"
  ),
  file.path(base, ".Rprofile")
)
base_script <- c(
  "library(targets)",
  "list(",
  "  tar_target(seed, 2L),",
  "  tar_target(large, rep(seed, 1000L)),",
  "  tar_target(",
  "    input_file,",
  "    {",
  "      path <- file.path(tar_config_get('store'), 'files', 'input.txt')",
  "      dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)",
  "      writeLines('base input', path)",
  "      path",
  "    },",
  "    format = 'file'",
  "  ),",
  "  tar_target(result, sum(large) + length(readLines(input_file))),",
  "  tar_target(numbers, c(1L, 2L), iteration = 'vector'),",
  "  tar_target(branch, numbers * 2L, pattern = map(numbers)),",
  "  tar_target(branch_sum, sum(unlist(branch))),",
  "  tar_target(unrelated, runif(1000L))",
  ")"
)
writeLines(base_script, file.path(base, "_targets.R"))
invisible(run(c(
  "git", "-C", base, "add",
  ".gitignore", ".Rprofile", "_targets.yaml", "_targets.R"
)))
invisible(run(c("git", "-C", base, "commit", "-m", "test project")))
invisible(run(c(
  "git", "-C", base, "worktree", "add", "-b", "test-worktree", worktree
)))

withr::with_dir(
  base,
  targets::tar_make(callr_function = NULL, reporter = "silent")
)
base_store <- file.path(base, "pipeline", "outputs")
snapshot <- file.path(base_store, ".snapshot", "snapshot-001")
create_snapshot <- function(path) {
  dir.create(path, recursive = TRUE)
  for (store_path in c("meta", "objects", "files")) {
    stopifnot(
      file.copy(file.path(base_store, store_path), path, recursive = TRUE)
    )
  }
  stopifnot(system2("chmod", c("-R", "a-w", path)) == 0L)
}
create_snapshot(snapshot)
remove_snapshot <- function(path) {
  stopifnot(system2("chmod", c("-R", "u+w", path)) == 0L)
  unlink(path, recursive = TRUE)
}
snapshot_checksums <- tools::md5sum(
  file.path(snapshot, c("meta/meta", "files/input.txt"))
)
runtime_source <- file.path(test_root, "runtime-source")
writeLines("runtime", runtime_source)

# Commands run in this R session, where `targets` is already loaded, unless a
# check needs the launcher itself: its flock and the guarded run process.
tool <- function(...) {
  withr::local_envvar(TARGETS_WORKTREE_LOCK_HELD = "1")
  utils::capture.output(targetsworktree::targets_worktree_cli(c(...)))
}
tool_error <- function(...) {
  message <- tryCatch({
    tool(...)
    NA_character_
  }, error = conditionMessage)
  stopifnot(!is.na(message))
  message
}
refuse_configure <- function(pattern, ...) {
  message <- tool_error("configure", "--project", worktree, "--base", base, ...)
  stopifnot(
    grepl(pattern, message, fixed = TRUE),
    is.null(read_state(worktree, required = FALSE))
  )
}

launcher <- targetsworktree::targets_worktree_executable()
launch <- function(...) {
  suppressWarnings(system2(
    launcher,
    c(...),
    stdout = TRUE,
    stderr = TRUE,
    env = paste0(
      "TARGETS_WORKTREE_RSCRIPT=",
      file.path(R.home("bin"), "Rscript")
    )
  ))
}
cli <- function(...) {
  output <- launch(...)
  if (!is.null(attr(output, "status"))) {
    stop(paste(output, collapse = "\n"))
  }
  output
}

# Configuration refuses the live store and never replaces an existing path.
refuse_configure("live base targets store", "--source", base_store)
sentinel <- file.path(store, "sentinel")
dir.create(store, recursive = TRUE)
writeLines("preserve", sentinel)
refuse_configure("already exists")
stopifnot(identical(readLines(sentinel), "preserve"))
unlink(store, recursive = TRUE)

# Discovery refuses to guess between snapshot naming families; a pattern
# selects the newest snapshot of one family.
family_snapshots <- file.path(
  base_store,
  ".snapshot",
  c("daily-2026-07-29", "daily-2026-07-30", "SIQ-replication-new")
)
for (path in family_snapshots) {
  create_snapshot(path)
}
refuse_configure("several naming families")
invisible(tool(
  "configure",
  "--project", worktree,
  "--base", base,
  "--snapshot-pattern", "^daily-"
))
stopifnot(identical(
  read_state(worktree)$source,
  normalizePath(family_snapshots[[2L]])
))
invisible(tool("teardown", "--project", worktree))
for (path in family_snapshots) {
  remove_snapshot(path)
}

# An expired snapshot stops runs, but teardown still removes its dangling link.
expiring_snapshot <- file.path(base_store, ".snapshot", "expiring")
create_snapshot(expiring_snapshot)
invisible(tool(
  "configure",
  "--project", worktree,
  "--base", base,
  "--source", expiring_snapshot
))
remove_snapshot(expiring_snapshot)
stopifnot(any(grepl(
  "^source status: +missing",
  tool("status", "--project", worktree)
)))
stopifnot(grepl(
  "no longer exists",
  tool_error("run", "--project", worktree, "--target", "large", "--local"),
  fixed = TRUE
))
invisible(tool("teardown", "--project", worktree))
stopifnot(!is_link(store), is.null(read_state(worktree, required = FALSE)))

# The base environment is linked only while both lock files match, and
# teardown removes only a link that configuration created.
pixi <- file.path(worktree, ".pixi")
dir.create(file.path(base, ".pixi"))
writeLines("lock 1", file.path(base, "pixi.lock"))
writeLines("lock 2", file.path(worktree, "pixi.lock"))
refuse_configure("pixi.lock differs")
writeLines("lock 1", file.path(worktree, "pixi.lock"))
invisible(tool("configure", "--project", worktree, "--base", base))
stopifnot(is_link(pixi))
invisible(tool("teardown", "--project", worktree))
stopifnot(!is_link(pixi))
stopifnot(file.symlink(normalizePath(file.path(base, ".pixi")), pixi))
invisible(tool("configure", "--project", worktree, "--base", base))
invisible(tool("teardown", "--project", worktree))
stopifnot(is_link(pixi))
unlink(c(pixi, file.path(c(base, worktree), "pixi.lock")))
unlink(file.path(base, ".pixi"), recursive = TRUE)

# Configuration links the snapshot read-only for inspection.
runtime_link <- file.path(worktree, "runtime-link")
invisible(tool(
  "configure",
  "--project", worktree,
  "--base", base,
  "--link", paste0("runtime-link=", runtime_source)
))
stopifnot(
  identical(normalizePath(store), normalizePath(snapshot)),
  is_link(runtime_link),
  identical(withr::with_dir(worktree, targets::tar_read(result)), 2001L)
)

# The launcher refuses to start while another operation holds the worktree lock.
lock <- system2(
  "git",
  c(
    "-C", worktree,
    "rev-parse", "--path-format=absolute",
    "--git-path", "targets-worktree/lock"
  ),
  stdout = TRUE
)
holder <- processx::process$new("flock", c(lock, "sleep", "5"), cleanup_tree = TRUE)
Sys.sleep(0.2)
stopifnot(!is.null(attr(launch("status", "--project", worktree), "status")))
invisible(holder$kill_tree())
invisible(holder$wait(timeout = 1000))

# Failed planning leaves the read-only worktree unchanged and unlocked.
invisible(tool_error(
  "run",
  "--project", worktree,
  "--target", "target_that_does_not_exist",
  "--local"
))
state <- read_state(worktree)
stopifnot(
  identical(state$mode, "read-only"),
  identical(state$phase, "ready"),
  is_link(store),
  !worktree_locked(worktree)
)

# The first run converts the store, links only its own closure, and locks the
# worktree so Git refuses to remove it, even with one --force.
invisible(cli("run", "--project", worktree, "--target", "large", "--local"))
state <- read_state(worktree)
stopifnot(
  identical(state$mode, "writable-selective"),
  setequal(state$links$name, c("seed", "large")),
  worktree_locked(worktree)
)
forced_removal <- suppressWarnings(system2(
  "git",
  c("-C", base, "worktree", "remove", "--force", worktree),
  stdout = TRUE,
  stderr = TRUE
))
stopifnot(!is.null(attr(forced_removal, "status")), dir.exists(store))

# A later run links the rest of its closure on demand, including file targets
# and dynamic branches.
invisible(cli(
  "run",
  "--project", worktree,
  "--target", "result",
  "--target", "branch_sum",
  "--local"
))
state <- read_state(worktree)
stopifnot(
  !"unrelated" %in% state$closure,
  "branch" %in% state$links$parent,
  is_link(file.path(store, "objects", "large")),
  is_link(file.path(store, "files", "input.txt")),
  !file.exists(file.path(store, "objects", "unrelated"))
)

# Another live targets process in the worktree blocks runs.
foreign_process <- processx::process$new("sleep", "60", cleanup_tree = TRUE)
writeLines(
  c(
    "name|value",
    paste0("pid|", foreign_process$get_pid()),
    paste0("created|", Sys.time()),
    paste0("version_targets|", as.character(utils::packageVersion("targets")))
  ),
  file.path(store, "meta", "process")
)
stopifnot(grepl(
  "already active",
  tool_error("run", "--project", worktree, "--target", "result", "--local"),
  fixed = TRUE
))
unlink(file.path(store, "meta", "process"))
invisible(foreign_process$kill_tree())
invisible(foreign_process$wait(timeout = 1000))

# Changed code rebuilds outdated values physically and never writes to the
# snapshot.
worktree_script <- sub("'base input'", "'worktree input'", base_script, fixed = TRUE)
worktree_script <- sub(
  "length(readLines(input_file))",
  "length(readLines(input_file)) + 10L",
  worktree_script,
  fixed = TRUE
)
worktree_script <- sub("numbers * 2L", "numbers * 3L", worktree_script, fixed = TRUE)
writeLines(worktree_script, file.path(worktree, "_targets.R"))
invisible(cli(
  "run",
  "--project", worktree,
  "--target", "result",
  "--target", "branch_sum",
  "--local"
))
scratch_input <- file.path(store, "files", "input.txt")
stopifnot(
  !is_link(scratch_input),
  identical(readLines(scratch_input), "worktree input"),
  identical(withr::with_dir(worktree, targets::tar_read(result)), 2011L),
  identical(withr::with_dir(worktree, targets::tar_read(branch_sum)), 9L),
  identical(
    tools::md5sum(file.path(snapshot, c("meta/meta", "files/input.txt"))),
    snapshot_checksums
  )
)

# Teardown validates every recorded path first, so a redirected link leaves the
# writable store, state, and lock in place.
other_source <- file.path(test_root, "other-source")
writeLines("other", other_source)
unlink(runtime_link)
stopifnot(file.symlink(other_source, runtime_link))
stopifnot(grepl(
  "no longer points to its recorded source",
  tool_error("teardown", "--project", worktree),
  fixed = TRUE
))
stopifnot(
  identical(read_state(worktree)$phase, "ready"),
  dir.exists(store) && !is_link(store),
  worktree_locked(worktree)
)
unlink(runtime_link)

# Teardown quarantines the writable store and removes its links and lock, so
# Git removes the worktree normally.
teardown <- tool("teardown", "--project", worktree)
quarantine <- trimws(sub(
  "^quarantine:",
  "",
  grep("^quarantine:", teardown, value = TRUE)
))
stopifnot(
  length(quarantine) == 1L,
  dir.exists(quarantine),
  !file.exists(store) && !is_link(store),
  is.null(read_state(worktree, required = FALSE)),
  !worktree_locked(worktree),
  identical(readLines(runtime_source), "runtime")
)
invisible(run(c("git", "-C", base, "worktree", "remove", "--force", worktree)))
stopifnot(!dir.exists(worktree))

cat(
  "targets-worktree integration passed\n",
  "  live store and existing paths refused: yes\n",
  "  snapshot families refused unless a pattern selects one: yes\n",
  "  expired snapshot stops runs; teardown still works: yes\n",
  "  Pixi linked only for matching locks; adopted links kept: yes\n",
  "  launcher lock excludes concurrent operations: yes\n",
  "  failed planning leaves the worktree read-only: yes\n",
  "  first run converts, links its closure, and locks: yes\n",
  "  later runs link files and branches on demand: yes\n",
  "  another live targets process blocks runs: yes\n",
  "  changed code rebuilds physically; snapshot unchanged: yes\n",
  "  teardown validates first, quarantines, and unlocks: yes\n",
  sep = ""
)
