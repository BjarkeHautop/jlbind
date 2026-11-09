test_that("@rcall declarations are found with their argument counts", {
  src <- '
    @rcall f()::Int64
    @rcall g(a::Int64)::Int64
    @rcall h(a::Union{Nothing,Int64}, b::Dict{String,Vector{Int64}})::SEXP
    @rcall multi(
        a::String,
        b::NTuple{2,Float64},
    )::RRef{Foo}
    @rcall  spaced  (x::Int64)::Int64
  '
  expect_equal(
    .find_rcalls(src)[c("name", "nargs")],
    data.frame(
      name = c("f", "g", "h", "multi", "spaced"),
      nargs = c(0L, 1L, 2L, 2L, 1L)
    )
  )
})

test_that("comments, strings and character literals are ignored", {
  src <- paste(readLines(test_path("fixtures", "tricky.jl")), collapse = "\n")
  expect_equal(
    .find_rcalls(src),
    data.frame(
      name = "real",
      nargs = 2L,
      formals = "x, y",
      args = "x, y",
      invisible = FALSE,
      roxygen = ""
    )
  )
  expect_null(.find_rcalls("x = 1"))
})

test_that("argument names and defaults become the R wrapper's formals", {
  src <- '
    @rcall f(x::Vector{Float64}, by::Union{Nothing,Float64} = nothing)::SEXP
    @rcall g(n::Int64 = -2, s::String = "a, \\"b\\" = c", ok::Bool = true)::SEXP
    @rcall h(d::Dict{String,Int64}=Dict(), x::Float64 = 1.5e-3)::SEXP
  '
  expect_error(.find_rcalls(src), "`d`.*literal")
  src <- sub("=Dict()", "", src, fixed = TRUE)
  entries <- .find_rcalls(src)
  expect_equal(
    entries$formals,
    c(
      "x, by = NULL",
      'n = -2, s = "a, \\"b\\" = c", ok = TRUE',
      "d, x = 1.5e-3"
    )
  )
  expect_equal(entries$args, c("x, by", "n, s, ok", "d, x"))
  expect_equal(entries$nargs, c(2L, 3L, 2L))
})

test_that("a function returning Nothing gets an invisible wrapper", {
  src <- '
    @rcall a(x::Int64)::Nothing
    @rcall b(x::Int64) :: Nothing  # spaced
    @rcall c(x::Union{Nothing,Int64})::Int64
    @rcall d()::NothingLike
    @rcall e()::Union{Nothing,Int64}
  '
  expect_equal(
    .find_rcalls(src)$invisible,
    c(TRUE, TRUE, FALSE, FALSE, FALSE)
  )
  entries <- data.frame(
    name = c("set", "get"),
    nargs = c(1L, 0L),
    formals = c("x", ""),
    args = c("x", ""),
    invisible = c(TRUE, FALSE),
    roxygen = c("", "")
  )
  expect_equal(
    tail(.wrappers(entries, "M"), 2L),
    c(
      "set <- function(x) invisible(.External(.jlbind$.call, .jlbind$set, x))",
      "get <- function() .External(.jlbind$.call, .jlbind$get)"
    )
  )
})

test_that("roxygen comments directly above a declaration are kept", {
  src <- paste(
    c(
      "#' Above a one-line declaration",
      "#' @export",
      "@rcall a(x::Int64)::Int64",
      "",
      "    #' Indented, above a multi-line declaration",
      "    @rcall b(",
      "        x::Int64,",
      "    )::Int64",
      "@rcall none(x::Int64)::Int64",
      "#' Separated by a blank line",
      "",
      "@rcall blank(x::Int64)::Int64",
      "# An ordinary comment",
      "@rcall plain(x::Int64)::Int64",
      "#' Interrupted",
      "# by an ordinary comment",
      "@rcall interrupted(x::Int64)::Int64"
    ),
    collapse = "\n"
  )
  expect_equal(
    .find_rcalls(src)$roxygen,
    c(
      "#' Above a one-line declaration\n#' @export",
      "#' Indented, above a multi-line declaration",
      "",
      "",
      "",
      ""
    )
  )
})

test_that("roxygen comments are written above the R wrapper", {
  entries <- data.frame(
    name = c("plain", "documented", "a_rather_long_name"),
    nargs = c(1L, 1L, 2L),
    formals = c("x", "x", "first_argument, second_argument = NULL"),
    args = c("x", "x", "first_argument, second_argument"),
    invisible = FALSE,
    roxygen = c("", "#' Title\n#' @export", "#' @rdname shared")
  )
  expect_equal(
    tail(.wrappers(entries, "M"), 10L),
    c(
      "plain <- function(x) .External(.jlbind$.call, .jlbind$plain, x)",
      "",
      "#' Title",
      "#' @export",
      "documented <- function(x) .External(.jlbind$.call, .jlbind$documented, x)",
      "",
      "#' @rdname shared",
      "a_rather_long_name <- function(first_argument, second_argument = NULL) {",
      "  .External(.jlbind$.call, .jlbind$a_rather_long_name, first_argument, second_argument)",
      "}"
    )
  )
})

test_that("arguments must be typed, with R names and literal defaults", {
  expect_error(.find_rcalls("@rcall f(x)::Int64"), "needs a type")
  expect_error(.find_rcalls("@rcall f(x!::Int64)::Int64"), "valid R argument")
  expect_error(
    .find_rcalls('@rcall f(s::String = "$x")::Int64'),
    "literal"
  )
  expect_error(.find_rcalls("@rcall f(x::Int64 = y)::Int64"), "literal")
})

test_that("keyword arguments and unbalanced declarations are rejected", {
  expect_error(
    .find_rcalls("@rcall f(a::Int; b::Int)::Int"),
    "keyword"
  )
  expect_error(.find_rcalls("@rcall f(a::Int"), "unbalanced")
})

test_that("update_entrypoints() writes the header the shim includes", {
  pkg <- local_client()
  writeLines(
    c(
      "module DemoBindings",
      "using JLBind",
      "@rcall nothing_in()::Int64",
      "@rcall two(a::String, b::Vector{Float64})::Float64",
      "end"
    ),
    file.path(pkg, "inst", "julia", "src", "DemoBindings.jl")
  )
  msgs <- capture_messages({
    entries <- update_entrypoints(pkg)
  })
  expect_match(msgs, "2 entrypoints", all = FALSE)
  expect_match(msgs, "jlbind-wrappers.R", all = FALSE)
  expect_equal(entries$name, c("nothing_in", "two"))
  wrappers <- readLines(file.path(pkg, "R", "jlbind-wrappers.R"))
  expect_equal(
    wrappers[-(1:5)],
    c(
      '.jlbind_module <- "DemoBindings"',
      ".jlbind_entries <- c(",
      '  "nothing_in",',
      '  "two"',
      ")",
      ".jlbind <- new.env(parent = emptyenv())",
      "",
      "nothing_in <- function() .External(.jlbind$.call, .jlbind$nothing_in)",
      "two <- function(a, b) .External(.jlbind$.call, .jlbind$two, a, b)"
    )
  )
  # Unchanged declarations leave the files alone.
  expect_no_message(update_entrypoints(pkg))
})

test_that("duplicate and non-C entrypoint names are rejected", {
  pkg <- local_client()
  file <- file.path(pkg, "inst", "julia", "src", "DemoBindings.jl")
  writeLines(c("@rcall f()::Int64", "@rcall f()::Int64"), file)
  expect_error(update_entrypoints(pkg), "More than one")
  writeLines("@rcall f!(x::Int64)::Int64", file)
  expect_error(update_entrypoints(pkg), "valid C identifier")
})

test_that("a binding package without entrypoints gets an empty list", {
  pkg <- local_client()
  unlink(file.path(pkg, "inst", "julia", "src"), recursive = TRUE)
  suppressMessages(entries <- update_entrypoints(pkg))
  expect_equal(nrow(entries), 0L)
  wrappers <- readLines(file.path(pkg, "R", "jlbind-wrappers.R"))
  expect_true(".jlbind_entries <- character()" %in% wrappers)
  expect_false(any(grepl("<- function", wrappers)))
})

test_that("long wrappers are split over lines", {
  entries <- data.frame(
    name = "a_rather_long_name",
    nargs = 2L,
    formals = "first_argument, second_argument = NULL",
    args = "first_argument, second_argument",
    invisible = FALSE,
    roxygen = ""
  )
  expect_equal(
    tail(.wrappers(entries, "M"), 3L),
    c(
      "a_rather_long_name <- function(first_argument, second_argument = NULL) {",
      "  .External(.jlbind$.call, .jlbind$a_rather_long_name, first_argument, second_argument)",
      "}"
    )
  )
})
