# Helpers of the tests that compile a library (test-integration.R,
# test-prebuilt.R), which skip unless asked to with an environment variable.

# The test clients in tests/clients that share one library.
test_clients <- c("convertjl", "counterjl", "hellojl")

# Skips unless libraries are to be built here, and returns the Julia to build
# them with.
skip_unless_build <- function(var = "JLBIND_TEST_BUILD") {
  skip_on_cran()
  skip_if_not(
    identical(Sys.getenv(var), "true"),
    paste0("set ", var, "=true to compile a library")
  )
  skip_if_not_installed("callr")
  julia <- tryCatch(.find_julia(), error = function(e) NULL)
  skip_if(is.null(julia), "Julia >= 1.13 not found")
  julia
}

# The test clients installed into a temporary library with their shared
# library built, once for all the tests that call them: `libpath` and `env`
# for callr, and `built`, what the build process saw.
shared <- new.env(parent = emptyenv())
shared_library <- function() {
  skip_unless_build()
  skip_if(isTRUE(shared$failed), "the shared library failed to build")
  if (is.null(shared$libpath)) {
    shared$failed <- TRUE
    data <- withr::local_tempdir(.local_envir = teardown_env())
    libpath <- local_install(
      file.path(test_path("..", "clients"), test_clients),
      env = teardown_env()
    )
    env <- c(
      callr::rcmd_safe_env(),
      R_USER_CACHE_DIR = data,
      R_USER_CONFIG_DIR = file.path(data, "config"),
      JULIA_NUM_THREADS = "2"
    )
    # The clients are loaded before the library is built, so install_library()
    # binds them.
    shared$built <- callr::r(
      function(clients) {
        for (pkg in clients) {
          library(pkg, character.only = TRUE)
        }
        before <- tryCatch(greet("x"), error = conditionMessage)
        found <- jlbind::jlbind_clients(.libPaths()[[1L]])$package
        suppressMessages(jlbind::install_library(clients, ask = FALSE))
        # Fail with the reason a client is not bound, if one is not.
        for (pkg in clients) {
          jlbind::check_bound(pkg)
        }
        list(before = before, found = sort(found))
      },
      args = list(clients = test_clients),
      libpath = libpath,
      env = env,
      show = TRUE
    )
    shared$libpath <- libpath
    shared$env <- env
    shared$failed <- FALSE
  }
  shared
}

# Calls `fun` in a fresh R process with the test clients and their shared
# library installed, with the variables `env` added to its environment.
call_shared <- function(fun, env = character()) {
  lib <- shared_library()
  vars <- lib$env
  vars[names(env)] <- env
  callr::r(fun, libpath = lib$libpath, env = vars, show = TRUE)
}
