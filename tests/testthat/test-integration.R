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
      suppressMessages(jlbind::install_backend(ask = FALSE))
      # Fail with the reason a client is not bound, if one is not.
      jlbind::check_backend("hellojl")
      jlbind::check_backend("counterjl")
      c1 <- new_counter(10)
      increment(c1, 5)
      for (i in 1:2000) {
        increment(new_counter(i))
      }
      gc()
      invisible(new_counter(0)) # drops the released handles
      f <- tempfile()
      saveRDS(c1, f)
      list(
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
        class = class(c1),
        counter = increment(c1),
        counters = vapply(counters(3), increment, 1, by = 100),
        wrong_ref = tryCatch(increment(list(), 1), error = conditionMessage),
        reloaded = tryCatch(increment(readRDS(f)), error = conditionMessage),
        live = live(),
        info = jlbind::backend_info()
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

  expect_match(res$before, "check_backend")
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
  expect_equal(res$bad_type, "expected a character string")
  expect_equal(res$na, "expected numbers, not NA")
  expect_equal(res$class, "counter")
  expect_equal(res$counter, 16)
  expect_equal(res$counters, c(101, 102, 103))
  expect_equal(res$wrong_ref, "expected a `counter` object")
  expect_match(res$reloaded, "no longer exists")
  # c1, the last stored, and the three from counters() unless collected.
  expect_lte(res$live, 5)
  expect_equal(sort(res$info$bound), c("counterjl", "hellojl"))
  expect_equal(sort(res$info$clients$Package), c("counterjl", "hellojl"))
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
