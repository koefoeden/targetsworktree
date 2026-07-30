script_argument <- commandArgs(trailingOnly = FALSE)[
  grepl("^--file=", commandArgs(trailingOnly = FALSE))
]
script_path <- sub("^--file=", "", script_argument)
runtime_root <- normalizePath(file.path(dirname(script_path), ".."), mustWork = TRUE)
source(file.path(runtime_root, "R", "targets_worktree_core.R"))

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
base_script <- c(
  "library(targets)",
  "list(",
  "  tar_target(seed, 2L),",
  "  tar_target(large, rep(seed, 100000L)),",
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
  "  tar_target(unrelated, runif(1000000L))",
  ")"
)
writeLines(base_script, file.path(base, "_targets.R"))
invisible(run(c(
  "git", "-C", base, "add",
  ".gitignore", "_targets.yaml", "_targets.R"
)))
invisible(run(c("git", "-C", base, "commit", "-m", "test project")))
invisible(run(c(
  "git", "-C", base, "worktree", "add", "-b", "test-worktree", worktree
)))

withr::with_dir(base, targets::tar_make(reporter = "silent"))
base_store <- file.path(base, "pipeline", "outputs")
snapshot <- file.path(base_store, ".snapshot", "snapshot-001")
dir.create(snapshot, recursive = TRUE)
for (path in c("meta", "objects", "files")) {
  stopifnot(file.copy(file.path(base_store, path), snapshot, recursive = TRUE))
}
stopifnot(system2("chmod", c("-R", "a-w", snapshot)) == 0L)
snapshot_meta_checksum <- unname(tools::md5sum(file.path(snapshot, "meta", "meta")))
snapshot_input_checksum <- unname(
  tools::md5sum(file.path(snapshot, "files", "input.txt"))
)
runtime_source <- file.path(test_root, "runtime-source")
writeLines("runtime", runtime_source)

launcher <- file.path(runtime_root, "targets-worktree")
rscript <- file.path(R.home("bin"), "Rscript")
cli <- function(...) {
  output <- system2(
    launcher,
    c(...),
    stdout = TRUE,
    stderr = TRUE,
    env = paste0("TARGETS_WORKTREE_RSCRIPT=", rscript)
  )
  status <- attr(output, "status")
  if (!is.null(status) && status != 0L) {
    stop(paste(output, collapse = "\n"))
  }
  output
}

invisible(cli(
  "configure",
  "--project", worktree,
  "--base", base,
  "--mode", "code",
  "--link", paste0("runtime-link=", runtime_source)
))
state <- shared_targets_worktree$read_state(worktree)
stopifnot(identical(state$mode, "code"))
stopifnot(!dir.exists(file.path(worktree, "pipeline", "outputs")))
stopifnot(identical(
  normalizePath(file.path(worktree, "runtime-link")),
  normalizePath(runtime_source)
))
invisible(cli("teardown", "--project", worktree))
stopifnot(is.null(shared_targets_worktree$read_state(worktree, required = FALSE)))
stopifnot(!file.exists(file.path(worktree, "runtime-link")))
stopifnot(identical(readLines(runtime_source), "runtime"))

stopifnot(file.symlink(runtime_source, file.path(worktree, "adopted-link")))
invisible(cli(
  "configure",
  "--project", worktree,
  "--base", base,
  "--mode", "code",
  "--link", paste0("adopted-link=", runtime_source)
))
stopifnot(!shared_targets_worktree$read_state(worktree)$runtime_links$managed)
invisible(cli("teardown", "--project", worktree))
stopifnot(nzchar(Sys.readlink(file.path(worktree, "adopted-link"))))
unlink(file.path(worktree, "adopted-link"))

live_source_status <- suppressWarnings(system2(
  launcher,
  c(
    "configure",
    "--project", worktree,
    "--base", base,
    "--mode", "read-only",
    "--source", base_store
  ),
  stdout = TRUE,
  stderr = TRUE,
  env = paste0("TARGETS_WORKTREE_RSCRIPT=", rscript)
))
stopifnot(!is.null(attr(live_source_status, "status")))
stopifnot(is.null(shared_targets_worktree$read_state(worktree, required = FALSE)))

sentinel <- file.path(worktree, "pipeline", "outputs", "sentinel")
dir.create(dirname(sentinel), recursive = TRUE)
writeLines("preserve", sentinel)
conflict_status <- suppressWarnings(system2(
  launcher,
  c(
    "configure",
    "--project", worktree,
    "--base", base,
    "--mode", "code"
  ),
  stdout = TRUE,
  stderr = TRUE,
  env = paste0("TARGETS_WORKTREE_RSCRIPT=", rscript)
))
stopifnot(!is.null(attr(conflict_status, "status")))
stopifnot(identical(readLines(sentinel), "preserve"))
unlink(file.path(worktree, "pipeline", "outputs"), recursive = TRUE)

outside <- file.path(test_root, "outside")
dir.create(outside)
stopifnot(file.symlink(outside, file.path(worktree, "escape")))
escape_status <- suppressWarnings(system2(
  launcher,
  c(
    "configure",
    "--project", worktree,
    "--base", base,
    "--mode", "code",
    "--link", paste0("escape/new-link=", runtime_source)
  ),
  stdout = TRUE,
  stderr = TRUE,
  env = paste0("TARGETS_WORKTREE_RSCRIPT=", rscript)
))
stopifnot(!is.null(attr(escape_status, "status")))
stopifnot(!file.exists(file.path(outside, "new-link")))
unlink(file.path(worktree, "escape"))

invisible(cli(
  "configure",
  "--project", worktree,
  "--base", base,
  "--mode", "read-only"
))
store <- file.path(worktree, "pipeline", "outputs")
stopifnot(nzchar(Sys.readlink(store)))
stopifnot(identical(normalizePath(store), normalizePath(snapshot)))
stopifnot(identical(withr::with_dir(worktree, targets::tar_read(result)), 200001L))

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
locked_status <- suppressWarnings(system2(
  launcher,
  c("status", "--project", worktree),
  stdout = TRUE,
  stderr = TRUE,
  env = paste0("TARGETS_WORKTREE_RSCRIPT=", rscript)
))
stopifnot(!is.null(attr(locked_status, "status")))
invisible(holder$kill_tree())
invisible(holder$wait(timeout = 1000))

invisible(cli("teardown", "--project", worktree))
stopifnot(!file.exists(store) && !dir.exists(store))

invisible(cli(
  "configure",
  "--project", worktree,
  "--base", base,
  "--mode", "writable-selective",
  "--target", "large"
))
state <- shared_targets_worktree$read_state(worktree)
stopifnot(all(state$links$kind == "object"))
stopifnot(setequal(state$links$name, c("seed", "large")))
invisible(cli("teardown", "--project", worktree))

invisible(cli(
  "configure",
  "--project", worktree,
  "--base", base,
  "--mode", "writable-selective",
  "--target", "result",
  "--target", "branch_sum"
))
state <- shared_targets_worktree$read_state(worktree)
stopifnot(identical(state$mode, "writable-selective"))
stopifnot(!"unrelated" %in% state$closure)
stopifnot(any(!is.na(state$links$parent) & state$links$parent == "branch"))
stopifnot(nzchar(Sys.readlink(file.path(store, "objects", "large"))))
stopifnot(nzchar(Sys.readlink(file.path(store, "files", "input.txt"))))
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
active_status <- suppressWarnings(system2(
  launcher,
  c(
    "run",
    "--project", worktree,
    "--target", "result",
    "--target", "branch_sum",
    "--local"
  ),
  stdout = TRUE,
  stderr = TRUE,
  env = paste0("TARGETS_WORKTREE_RSCRIPT=", rscript)
))
stopifnot(!is.null(attr(active_status, "status")))
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
stopifnot(is.null(shared_targets_worktree$read_state(worktree)$quarantine))
stopifnot(!nzchar(Sys.readlink(scratch_input)))
stopifnot(identical(readLines(scratch_input), "worktree input"))
stopifnot(identical(withr::with_dir(worktree, targets::tar_read(result)), 200011L))
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
stopifnot(!file.exists(store) && !dir.exists(store))
stopifnot(is.null(shared_targets_worktree$read_state(worktree, required = FALSE)))

cat(
  "targets-worktree integration passed\n",
  "  configured nested store: yes\n",
  "  code/read-only/selective modes: yes\n",
  "  managed/adopted runtime links: yes\n",
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
