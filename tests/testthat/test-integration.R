# Builds a library from the two test clients in tests/clients and calls them
# from one R process. Compiling takes a minute or more, so it only runs when
# JLBIND_TEST_BUILD=true.

test_that("two clients share one compiled library", {
  skip_on_cran()
  skip_if_not(
    identical(Sys.getenv("JLBIND_TEST_BUILD"), "true"),
    "set JLBIND_TEST_BUILD=true to compile a library"
  )
  skip_if_not_installed("callr")
  julia <- tryCatch(.find_julia(), error = function(e) NULL)
  skip_if(is.null(julia), "Julia >= 1.13 not found")

  data <- withr::local_tempdir()
  clients <- test_path("..", "clients")
  libpath <- local_install(
    file.path(clients, "hellojl"),
    file.path(clients, "counterjl")
  )

  res <- callr::r(
    function() {
      library(hellojl)
      library(counterjl)
      before <- tryCatch(greet("x"), error = conditionMessage)
      found <- jlbind::jlbind_clients()$package
      suppressMessages(jlbind::install_library(ask = FALSE))
      # Fail with the reason a client is not bound, if one is not.
      jlbind::check_bound("hellojl")
      jlbind::check_bound("counterjl")
      c1 <- new_counter(10)
      increment(c1, 5)
      for (i in 1:2000) {
        increment(new_counter(i))
      }
      gc()
      invisible(new_counter(0)) # drops the released handles
      f <- tempfile()
      saveRDS(c1, f)
      err <- function(expr) tryCatch(expr, error = conditionMessage)
      bytes <- "\xe9"
      Encoding(bytes) <- "bytes"
      # Arguments R itself cannot convert must fail in Julia, not by an R
      # error unwinding through Julia, after which the next Julia exception
      # (`fail` below) crashes R.
      bad <- list(
        raw = err(evens(as.raw(4))),
        list = err(evens(list(4))),
        string = err(evens("4")),
        warn2 = local({
          op <- options(warn = 2)
          on.exit(options(op))
          err(evens("x"))
        }),
        logical_number = err(negate(1)),
        logical_raw = err(negate(as.raw(1))),
        logical_na = err(negate(NA)),
        bytes = err(greet(bytes)),
        nul = err(with_nul("a"))
      )
      list(
        bad = bad,
        int_arg = evens(4L),
        negate = negate(TRUE),
        before = before,
        found = sort(found),
        bound = c(jlbind::is_bound("hellojl"), jlbind::is_bound("counterjl")),
        greet = greet("R"),
        shift = shift(1:3, 0.5),
        shift_null = shift(c(1, 2)),
        describe = describe(c(1, 5, 9)),
        upper = upper(c("a", "bé")),
        evens = evens(6),
        threads = threads(),
        fail = tryCatch(fail("custom failure"), error = conditionMessage),
        bad_type = tryCatch(greet(1), error = conditionMessage),
        na = tryCatch(shift(c(1, NA)), error = conditionMessage),
        nan = tryCatch(shift(c(1, NaN)), error = conditionMessage),
        class = class(c1),
        counter = increment(c1),
        counters = vapply(counters(3), increment, 1, by = 100),
        wrong_ref = tryCatch(increment(list(), 1), error = conditionMessage),
        reloaded = tryCatch(increment(readRDS(f)), error = conditionMessage),
        live = live(),
        info = jlbind::library_info()
      )
    },
    libpath = libpath,
    env = c(
      callr::rcmd_safe_env(),
      R_USER_DATA_DIR = data,
      JULIA_NUM_THREADS = "2"
    ),
    show = TRUE
  )

  expect_match(res$before, "check_bound")
  expect_equal(res$found, c("counterjl", "hellojl"))
  expect_equal(res$bound, c(TRUE, TRUE))
  expect_equal(res$greet, "Hello, R!")
  expect_equal(res$shift, c(1.5, 2.5, 3.5))
  expect_equal(res$shift_null, c(1, 2))
  expect_equal(res$describe, list(n = 3, mean = 5, range = c(1, 9)))
  expect_equal(res$upper, c("A", "BÉ"))
  expect_identical(res$evens, c(2L, 4L, 6L))
  expect_equal(res$threads, 2)
  expect_equal(res$fail, "custom failure")
  expect_equal(
    res$bad,
    list(
      raw = "expected a number",
      list = "expected a number",
      string = "expected a number",
      warn2 = "expected a number",
      logical_number = "expected TRUE or FALSE",
      logical_raw = "expected TRUE or FALSE",
      logical_na = "expected TRUE or FALSE, not NA",
      bytes = "expected text, not a string in \"bytes\" encoding",
      nul = "cannot return a string containing NUL to R"
    )
  )
  expect_identical(res$int_arg, c(2L, 4L))
  expect_false(res$negate)
  expect_equal(res$bad_type, "expected a character string")
  expect_equal(res$na, "expected numbers, not NA")
  expect_equal(res$nan, "expected numbers, not NaN")
  expect_equal(res$class, "counter")
  expect_equal(res$counter, 16)
  expect_equal(res$counters, c(101, 102, 103))
  expect_equal(res$wrong_ref, "expected a `counter` object")
  expect_match(res$reloaded, "no longer exists")
  # c1, the last stored, and the three from counters() unless collected.
  expect_lte(res$live, 5)
  clients <- res$info$clients
  expect_equal(sort(clients$package), c("counterjl", "hellojl"))
  expect_true(all(clients$included & clients$bound))
})

# A client that sets Config/jlbind/trim: false makes the library build without
# --trim. That build is much larger and slower, so it only runs when
# JLBIND_TEST_NOTRIM=true.
test_that("a client can turn trimming off", {
  skip_on_cran()
  skip_if_not(
    identical(Sys.getenv("JLBIND_TEST_NOTRIM"), "true"),
    "set JLBIND_TEST_NOTRIM=true to compile an untrimmed library"
  )
  skip_if_not_installed("callr")
  julia <- tryCatch(.find_julia(), error = function(e) NULL)
  skip_if(is.null(julia), "Julia >= 1.13 not found")

  src <- withr::local_tempdir()
  file.copy(test_path("..", "clients", "hellojl"), src, recursive = TRUE)
  pkg <- file.path(src, "hellojl")
  cat(
    "Config/jlbind/trim: false\n",
    file = file.path(pkg, "DESCRIPTION"),
    append = TRUE
  )
  expect_false(.client_info(pkg)$trim)

  out <- withr::local_tempdir()
  expect_message(
    path <- build_library(pkg, out, julia = julia),
    "without --trim, because hellojl"
  )
  build <- read.dcf(file.path(out, "build"))
  expect_equal(build[, "Trim"][[1]], "FALSE")

  libpath <- local_install(pkg)
  res <- callr::r(
    function() {
      library(hellojl)
      list(
        bound = jlbind::is_bound("hellojl"),
        greet = greet("R"),
        evens = evens(6),
        fail = tryCatch(fail("custom failure"), error = conditionMessage)
      )
    },
    libpath = libpath,
    env = c(callr::rcmd_safe_env(), JLBIND_LIBRARY = path),
    show = TRUE
  )
  expect_true(res$bound)
  expect_equal(res$greet, "Hello, R!")
  expect_identical(res$evens, c(2L, 4L, 6L))
  expect_equal(res$fail, "custom failure")
})
