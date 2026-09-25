read_state <- getFromNamespace("read_state", "targetsworktree")
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

withr::with_dir(base, targets::tar_make(reporter = "silent"))
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
snapshot_meta_checksum <- unname(tools::md5sum(file.path(snapshot, "meta", "meta")))
snapshot_input_checksum <- unname(
  tools::md5sum(file.path(snapshot, "files", "input.txt"))
)
runtime_source <- file.path(test_root, "runtime-source")
writeLines("runtime", runtime_source)

launcher <- targetsworktree::targets_worktree_executable()
rscript <- file.path(R.home("bin"), "Rscript")
launch <- function(...) {
  suppressWarnings(system2(
    launcher,
    c(...),
    stdout = TRUE,
    stderr = TRUE,
    env = paste0("TARGETS_WORKTREE_RSCRIPT=", rscript)
  ))
}
cli <- function(...) {
  output <- launch(...)
  if (!is.null(attr(output, "status"))) {
    stop(paste(output, collapse = "\n"))
  }
  output
}
cli_failure <- function(...) {
  output <- launch(...)
  stopifnot(!is.null(attr(output, "status")))
  output
}

unconfigured_status <- cli_failure("status", "--project", worktree)
stopifnot(any(grepl("No targets-worktree state exists", unconfigured_status)))
stopifnot(!file.exists(file.path(worktree, "pipeline", "outputs")))

invisible(cli(
  "configure",
  "--project", worktree,
  "--base", base,
  "--link", paste0("runtime-link=", runtime_source)
))
state <- read_state(worktree)
stopifnot(identical(state$mode, "read-only"))
stopifnot(is_link(file.path(worktree, "pipeline", "outputs")))
stopifnot(identical(
  normalizePath(file.path(worktree, "runtime-link")),
  normalizePath(runtime_source)
))
bad_option <- cli_failure("status", "--project", worktree, "--target", "large")
stopifnot(any(grepl("Unexpected argument for status", bad_option, fixed = TRUE)))

# Teardown validates every recorded path before changing anything, and skips
# recorded links that are already gone.
other_source <- file.path(test_root, "other-source")
writeLines("other", other_source)
unlink(file.path(worktree, "runtime-link"))
stopifnot(file.symlink(other_source, file.path(worktree, "runtime-link")))
redirected <- cli_failure("teardown", "--project", worktree)
stopifnot(any(grepl("no longer points to its recorded source", redirected, fixed = TRUE)))
stopifnot(identical(read_state(worktree)$phase, "ready"))
stopifnot(is_link(file.path(worktree, "pipeline", "outputs")))
unlink(file.path(worktree, "runtime-link"))
invisible(cli("teardown", "--project", worktree))
stopifnot(is.null(read_state(worktree, required = FALSE)))
stopifnot(!is_link(file.path(worktree, "pipeline", "outputs")))
stopifnot(identical(readLines(runtime_source), "runtime"))

daily_snapshot_old <- file.path(base_store, ".snapshot", "daily-2026-07-29")
daily_snapshot_new <- file.path(base_store, ".snapshot", "daily-2026-07-30")
replication_snapshot <- file.path(base_store, ".snapshot", "SIQ-replication-new")
create_snapshot(daily_snapshot_old)
create_snapshot(daily_snapshot_new)
create_snapshot(replication_snapshot)
mixed_families <- cli_failure("configure", "--project", worktree, "--base", base)
stopifnot(any(grepl("several naming families", mixed_families, fixed = TRUE)))
stopifnot(is.null(read_state(worktree, required = FALSE)))

snapshot_pattern <- "^daily-[0-9]{4}-[0-9]{2}-[0-9]{2}$"
pattern_status <- cli(
  "configure",
  "--project", worktree,
  "--base", base,
  "--snapshot-pattern", snapshot_pattern
)
state <- read_state(worktree)
stopifnot(identical(state$source, normalizePath(daily_snapshot_new)))
stopifnot(identical(state$snapshot_pattern, snapshot_pattern))
stopifnot(any(grepl("^snapshot pattern:", pattern_status)))
invisible(cli("teardown", "--project", worktree))

missing_pattern_status <- cli_failure(
  "configure",
  "--project", worktree,
  "--base", base,
  "--snapshot-pattern", "^missing-family-"
)
stopifnot(any(grepl("matching pattern", missing_pattern_status, fixed = TRUE)))
stopifnot(is.null(read_state(worktree, required = FALSE)))
stopifnot(!file.exists(file.path(worktree, "pipeline", "outputs")))

source_and_pattern_status <- cli_failure(
  "configure",
  "--project", worktree,
  "--base", base,
  "--source", snapshot,
  "--snapshot-pattern", "^snapshot-"
)
stopifnot(any(grepl("either an explicit source", source_and_pattern_status)))
stopifnot(is.null(read_state(worktree, required = FALSE)))
for (path in c(daily_snapshot_old, daily_snapshot_new, replication_snapshot)) {
  remove_snapshot(path)
}

# An expired snapshot leaves a dangling store link that teardown still removes.
expiring_snapshot <- file.path(base_store, ".snapshot", "expiring")
create_snapshot(expiring_snapshot)
invisible(cli(
  "configure",
  "--project", worktree,
  "--base", base,
  "--source", expiring_snapshot
))
remove_snapshot(expiring_snapshot)
expired_status <- cli("status", "--project", worktree)
stopifnot(any(grepl("^source status: +missing", expired_status)))
expired_conversion <- cli_failure(
  "convert",
  "--project", worktree,
  "--target", "large"
)
stopifnot(any(grepl("no longer exists", expired_conversion, fixed = TRUE)))
stopifnot(identical(read_state(worktree)$mode, "read-only"))
invisible(cli("teardown", "--project", worktree))
stopifnot(!is_link(file.path(worktree, "pipeline", "outputs")))
stopifnot(is.null(read_state(worktree, required = FALSE)))

stopifnot(file.symlink(runtime_source, file.path(worktree, "adopted-link")))
invisible(cli(
  "configure",
  "--project", worktree,
  "--base", base,
  "--link", paste0("adopted-link=", runtime_source)
))
stopifnot(!read_state(worktree)$runtime_links$managed)
invisible(cli("teardown", "--project", worktree))
stopifnot(is_link(file.path(worktree, "adopted-link")))
unlink(file.path(worktree, "adopted-link"))

# The base environment is linked only while both lock files match; a worktree
# environment of its own is used as it is.
dir.create(file.path(base, ".pixi"))
writeLines("lock 1", file.path(base, "pixi.lock"))
writeLines("lock 2", file.path(worktree, "pixi.lock"))
lock_failure <- cli_failure("configure", "--project", worktree, "--base", base)
stopifnot(any(grepl("pixi.lock differs", lock_failure, fixed = TRUE)))
stopifnot(is.null(read_state(worktree, required = FALSE)))
writeLines("lock 1", file.path(worktree, "pixi.lock"))
invisible(cli("configure", "--project", worktree, "--base", base))
stopifnot(is_link(file.path(worktree, ".pixi")))
invisible(cli("teardown", "--project", worktree))
stopifnot(!is_link(file.path(worktree, ".pixi")))
dir.create(file.path(worktree, ".pixi"))
writeLines("lock 2", file.path(worktree, "pixi.lock"))
invisible(cli("configure", "--project", worktree, "--base", base))
stopifnot(!is_link(file.path(worktree, ".pixi")))
invisible(cli("teardown", "--project", worktree))
stopifnot(dir.exists(file.path(worktree, ".pixi")))
unlink(file.path(c(base, worktree), ".pixi"), recursive = TRUE)
unlink(file.path(c(base, worktree), "pixi.lock"))

invisible(cli_failure(
  "configure",
  "--project", worktree,
  "--base", base,
  "--source", base_store
))
stopifnot(is.null(read_state(worktree, required = FALSE)))

sentinel <- file.path(worktree, "pipeline", "outputs", "sentinel")
dir.create(dirname(sentinel), recursive = TRUE)
writeLines("preserve", sentinel)
invisible(cli_failure("configure", "--project", worktree, "--base", base))
stopifnot(identical(readLines(sentinel), "preserve"))
unlink(file.path(worktree, "pipeline", "outputs"), recursive = TRUE)

outside <- file.path(test_root, "outside")
dir.create(outside)
stopifnot(file.symlink(outside, file.path(worktree, "escape")))
invisible(cli_failure(
  "configure",
  "--project", worktree,
  "--base", base,
  "--link", paste0("escape/new-link=", runtime_source)
))
stopifnot(!file.exists(file.path(outside, "new-link")))
unlink(file.path(worktree, "escape"))

invisible(cli(
  "configure",
  "--project", worktree,
  "--base", base
))
store <- file.path(worktree, "pipeline", "outputs")
stopifnot(is_link(store))
stopifnot(identical(normalizePath(store), normalizePath(snapshot)))
stopifnot(identical(withr::with_dir(worktree, targets::tar_read(result)), 2001L))

lock <- system2(
  "git",
  c(
    "-C", worktree,
    "rev-parse", "--path-format=absolute",
    "--git-path", "targets-worktree/lock"
  ),
  stdout = TRUE
)
holder <- processx::process$new(
  "flock",
  c(lock, "sleep", "5"),
  cleanup_tree = TRUE
)
Sys.sleep(0.2)
invisible(cli_failure("status", "--project", worktree))
invisible(holder$kill_tree())
invisible(holder$wait(timeout = 1000))

invisible(cli_failure(
  "convert",
  "--project", worktree,
  "--target", "target_that_does_not_exist"
))
state <- read_state(worktree)
stopifnot(identical(state$mode, "read-only"))
stopifnot(identical(state$phase, "ready"))
stopifnot(is_link(store))

invisible(cli("teardown", "--project", worktree))
stopifnot(!file.exists(store) && !is_link(store))

invisible(cli(
  "configure",
  "--project", worktree,
  "--base", base
))
invisible(cli(
  "convert",
  "--project", worktree,
  "--target", "large"
))
state <- read_state(worktree)
stopifnot(all(state$links$kind == "object"))
stopifnot(setequal(state$links$name, c("seed", "large")))
invisible(cli("teardown", "--project", worktree))

invisible(cli(
  "configure",
  "--project", worktree,
  "--base", base
))
invisible(cli(
  "convert",
  "--project", worktree,
  "--target", "result",
  "--target", "branch_sum"
))
state <- read_state(worktree)
stopifnot(identical(state$mode, "writable-selective"))
stopifnot(!"unrelated" %in% state$closure)
stopifnot(any(!is.na(state$links$parent) & state$links$parent == "branch"))
stopifnot(is_link(file.path(store, "objects", "large")))
stopifnot(is_link(file.path(store, "files", "input.txt")))
stopifnot(!file.exists(file.path(store, "objects", "unrelated")))

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
stopifnot(identical(
  as.integer(targets::tar_pid(store = store)),
  as.integer(foreign_process$get_pid())
))
invisible(cli_failure(
  "run",
  "--project", worktree,
  "--target", "result",
  "--target", "branch_sum",
  "--local"
))
unlink(file.path(store, "meta", "process"))
invisible(foreign_process$kill_tree())
invisible(foreign_process$wait(timeout = 1000))

worktree_script <- sub(
  "writeLines\\('base input', path\\)",
  "writeLines('worktree input', path)",
  base_script
)
worktree_script <- sub(
  "sum\\(large\\) \\+ length\\(readLines\\(input_file\\)\\)",
  "sum(large) + length(readLines(input_file)) + 10L",
  worktree_script
)
worktree_script <- sub(
  "numbers \\* 2L",
  "numbers * 3L",
  worktree_script
)
writeLines(worktree_script, file.path(worktree, "_targets.R"))
invisible(cli(
  "run",
  "--project", worktree,
  "--target", "result",
  "--target", "branch_sum",
  "--local"
))

scratch_input <- file.path(store, "files", "input.txt")
stopifnot(is.null(read_state(worktree)$quarantine))
stopifnot(!is_link(scratch_input))
stopifnot(identical(readLines(scratch_input), "worktree input"))
stopifnot(identical(withr::with_dir(worktree, targets::tar_read(result)), 2011L))
stopifnot(identical(
  withr::with_dir(worktree, targets::tar_read(branch_sum)),
  9L
))
stopifnot(
  identical(
    unname(tools::md5sum(file.path(snapshot, "meta", "meta"))),
    snapshot_meta_checksum
  )
)
stopifnot(
  identical(
    unname(tools::md5sum(file.path(snapshot, "files", "input.txt"))),
    snapshot_input_checksum
  )
)

teardown <- cli("teardown", "--project", worktree)
quarantine_line <- grep("^quarantine:", teardown, value = TRUE)
stopifnot(length(quarantine_line) == 1L)
quarantine <- trimws(sub("^quarantine:", "", quarantine_line))
stopifnot(dir.exists(quarantine))
stopifnot(!file.exists(store) && !is_link(store))
stopifnot(is.null(read_state(worktree, required = FALSE)))

cat(
  "targets-worktree integration passed\n",
  "  configured nested store: yes\n",
  "  read-only default and selective conversion: yes\n",
  "  per-command option validation: yes\n",
  "  teardown validates first and resumes: yes\n",
  "  mixed snapshot families refused without a pattern: yes\n",
  "  expired snapshot reported and torn down: yes\n",
  "  failed conversion planning preserves read-only state: yes\n",
  "  managed/adopted runtime links: yes\n",
  "  Pixi lock guard and worktree environment: yes\n",
  "  live source and conflicting path refused: yes\n",
  "  escaping symlink ancestor refused: yes\n",
  "  exclusive launcher lock: yes\n",
  "  foreign live targets PID refused: yes\n",
  "  zero-file selective closure: yes\n",
  "  dynamic branch ownership/rebuild: yes\n",
  "  target-aware reuse: yes\n",
  "  changed file target rebuilt physically: yes\n",
  "  immutable source unchanged: yes\n",
  "  writable store quarantined on teardown: yes\n",
  sep = ""
)
