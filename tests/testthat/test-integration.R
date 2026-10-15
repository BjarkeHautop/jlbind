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
  skip_if(is.null(julia), "Julia >= 1.14 not found")

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
      ints_vec <- 1:3
      conv <- list(
        na_doubles = na_doubles(c(1, NA, NaN)),
        na_doubles_int = na_doubles(c(1L, NA)),
        na_doubles_lgl = na_doubles(c(NA, NA)),
        na_wholes = na_wholes(c(1, NA)),
        na_ints = na_ints(c(1L, NA)),
        na_bools = na_bools(c(TRUE, NA, FALSE)),
        na_strings = na_strings(c("a", NA)),
        na_factor = na_strings(factor(c("b", NA, "a"))),
        maybe_na = maybe_double(NA),
        maybe_nan = maybe_double(NaN),
        maybe_value = maybe_double(2L),
        maybe_string = maybe_string(NA),
        ints = ints(c(1, 2)),
        transposed = transposed(matrix(1:6, 2)),
        cube = cube(array(1:24 / 2, c(2, 3, 4))),
        factor = strings(factor(c("x", "y", "x"))),
        raw = reverse_raw(as.raw(1:3)),
        conjugate = conjugate(c(1 + 2i, 3)),
        conjugate_real = conjugate(c(1, 2)),
        view_sum = view_sum(c(1, 2, 3.5)),
        view_same = identical(view_same(ints_vec), ints_vec),
        list_lengths = list_lengths(list(1, c(1, 2), numeric())),
        pair = pair(list("a", 2)),
        columns = columns(data.frame(b = factor(c("x", "y")), a = c(1, 2))),
        counts = counts(list(b = 2, a = 1L)),
        counts_empty = counts(list()),
        dates = dates(as.Date(c("2024-02-29", NA, "1969-12-31"))),
        dates_frac = dates(structure(c(19000.7, -0.5), class = "Date")),
        dates_int = dates(structure(19000L, class = "Date")),
        next_day = next_day(as.Date("2024-02-28")),
        times = times(.POSIXct(c(1704164645.25, NA), tz = "UTC")),
        times_ny = times(.POSIXct(1704164645, tz = "America/New_York")),
        na_complex = na_complex(c(1 + 2i, NA)),
        na_complex_real = na_complex(c(1, NA)),
        maybe_complex = maybe_complex(NA),
        symbol_counts = symbol_counts(list(b = 2, a = 1)),
        singles = singles(c(1.5, 2L)),
        shorts = shorts(c(1L, NA, -32768)),
        small_types = small_types(-128L, 65535, 4e9, 0.5),
        group_means = group_means(
          data.frame(x = c(1, 2, NA), group = factor(c("b", "a", "b")))
        )
      )
      conv_bad <- list(
        int32 = err(ints(3e9)),
        int32_na = err(ints(c(1L, NA))),
        whole_nan = err(na_wholes(NaN)),
        not_matrix = err(transposed(1:6)),
        cube_dims = err(cube(matrix(1, 2, 2))),
        view_int = err(view_sum(1:3)),
        complex_na = err(conjugate(c(1i, NA))),
        maybe_long = err(maybe_double(c(NA, NA))),
        list_elt = err(list_lengths(list(1, "a"))),
        pair_length = err(pair(list("a"))),
        pair_elt = err(pair(list("a", 1.5))),
        missing_col = err(columns(list(a = 1))),
        extra_col = err(columns(list(a = 1, b = "x", c = 2))),
        dup_col = err(columns(setNames(list(1, "x", 2), c("a", "b", "a")))),
        unnamed = err(counts(list(1))),
        dup_key = err(counts(setNames(list(1, 2), c("a", "a")))),
        dict_elt = err(counts(list(a = "x"))),
        unnamed_col = err(columns(list(a = 1, "x"))),
        empty_lgl = err(na_strings(logical())),
        int_min = err(int_min()),
        not_date = err(dates(19000)),
        time_as_date = err(next_day(Sys.time())),
        date_na = err(next_day(as.Date(NA))),
        dates_long = err(next_day(as.Date(c("2024-01-01", "2024-01-02")))),
        not_time = err(times(as.Date("2024-01-01"))),
        not_complex = err(maybe_complex("a")),
        single_range = err(singles(1e300)),
        short_range = err(shorts(40000)),
        unsigned_range = err(small_types(0L, 0, -1, 0)),
        not_frame = err(group_means(list(x = 1, group = "a"))),
        frame_col = err(group_means(data.frame(x = 1, group = "a", y = 2))),
        uneven = err(uneven())
      )
      list(
        conv = conv,
        conv_bad = conv_bad,
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
        total = total(list(c1, c1)),
        total_bad = tryCatch(total(list(c1, 1)), error = conditionMessage),
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
  conv <- res$conv
  expect_identical(conv$na_doubles, c(1, NA, NaN))
  expect_identical(conv$na_doubles_int, c(1, NA))
  expect_identical(conv$na_doubles_lgl, c(NA_real_, NA_real_))
  expect_identical(conv$na_wholes, c(1, NA))
  expect_identical(conv$na_ints, c(1L, NA))
  expect_identical(conv$na_bools, c(TRUE, NA, FALSE))
  expect_identical(conv$na_strings, c("a", NA))
  expect_identical(conv$na_factor, c("b", NA, "a"))
  expect_identical(conv$maybe_na, NA_real_)
  expect_identical(conv$maybe_nan, NaN)
  expect_identical(conv$maybe_value, 2)
  expect_identical(conv$maybe_string, NA_character_)
  expect_identical(conv$ints, 1:2)
  expect_identical(conv$transposed, t(matrix(1:6, 2)))
  expect_identical(conv$cube, array(1:24 / 2, c(2, 3, 4)))
  expect_identical(conv$factor, c("x", "y", "x"))
  expect_identical(conv$raw, as.raw(3:1))
  expect_identical(conv$conjugate, c(1 - 2i, 3 + 0i))
  expect_identical(conv$conjugate_real, c(1 + 0i, 2 + 0i))
  expect_identical(conv$view_sum, 6.5)
  expect_true(conv$view_same)
  expect_identical(conv$list_lengths, c(1, 2, 0))
  expect_identical(conv$pair, list("a", 2))
  expect_identical(conv$columns, list(a = c(1, 2), b = c("x", "y")))
  expect_identical(conv$counts, list(a = 1, b = 2))
  expect_length(conv$counts_empty, 0)
  expect_identical(conv$dates, as.Date(c("2024-02-29", NA, "1969-12-31")))
  expect_identical(conv$dates_frac, as.Date(c(19000, -1)))
  expect_identical(conv$dates_int, as.Date(19000))
  expect_identical(conv$next_day, as.Date("2024-02-29"))
  expect_identical(
    conv$group_means,
    data.frame(
      group = c("a", "b"),
      mean = c(2, NA),
      first = as.Date(c("2024-01-01", "2024-01-01"))
    )
  )
  expect_identical(conv$times, .POSIXct(c(1704164645.25, NA), tz = "UTC"))
  expect_identical(conv$times_ny, .POSIXct(1704164645, tz = "UTC"))
  expect_identical(conv$na_complex, c(1 + 2i, NA_complex_))
  expect_identical(conv$na_complex_real, c(1 + 0i, NA_complex_))
  expect_identical(conv$maybe_complex, NA_complex_)
  expect_identical(conv$symbol_counts, list(a = 1, b = 2))
  expect_identical(conv$singles, c(3, 4))
  expect_identical(conv$shorts, c(1L, NA, -32768L))
  expect_identical(conv$small_types, list(-128L, 65535L, 4e9, 0.5))
  expect_equal(
    res$conv_bad,
    list(
      int32 = "expected a whole number between -2147483647 and 2147483647, not 3.0e9",
      int32_na = "expected numbers, not NA",
      whole_nan = "expected a whole number, not NaN",
      not_matrix = "expected a matrix",
      cube_dims = "expected an array of 3 dimensions",
      view_int = "expected a double vector",
      complex_na = "expected complex numbers, not NA",
      maybe_long = "expected a single number",
      list_elt = "element 2: expected a numeric vector",
      pair_length = "expected a list of length 2",
      pair_elt = "element 2: expected a whole number, not 1.5",
      missing_col = "expected a list with an element `b`",
      extra_col = "unexpected element `c`",
      dup_col = "duplicate element `a`",
      unnamed = "expected a named list",
      dup_key = "duplicate element `a`",
      dict_elt = "element `a`: expected a number",
      unnamed_col = "expected a named list",
      empty_lgl = "expected a character vector",
      int_min = "cannot return -2147483648 to R as an integer, where it is NA",
      not_date = "expected a Date",
      time_as_date = "expected a Date",
      date_na = "expected a Date, not NA",
      dates_long = "expected a single Date",
      not_time = "expected a date-time",
      not_complex = "expected a complex number",
      single_range = paste(
        "expected a number between -3.4028234663852886e38 and",
        "3.4028234663852886e38, not 1.0e300"
      ),
      short_range = "expected a whole number between -32768 and 32767, not 40000.0",
      unsigned_range = "expected a whole number between 0 and 4294967295, not -1.0",
      not_frame = "expected a data frame",
      frame_col = "unexpected element `y`",
      uneven = paste(
        "the columns of a data frame must have equal lengths,",
        "but `a` has 1 and `b` 2"
      )
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
  expect_equal(res$total, 32)
  expect_equal(res$total_bad, "element 2: expected a `counter` object")
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
  skip_if(is.null(julia), "Julia >= 1.14 not found")

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
