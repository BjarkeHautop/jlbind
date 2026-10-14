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
    .find_rcalls(src),
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
    data.frame(name = "real", nargs = 2L)
  )
  expect_null(.find_rcalls("x = 1"))
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
  expect_message(entries <- update_entrypoints(pkg), "2 entrypoints")
  expect_equal(entries$name, c("nothing_in", "two"))
  header <- readLines(file.path(pkg, "src", "entrypoints.h"))
  expect_true('#define JLBIND_PREFIX "DemoBindings_"' %in% header)
  expect_true(
    "    JLBIND_ENTRY(nothing_in, 0, (void), ()) \\" %in% header
  )
  expect_true(
    "    JLBIND_ENTRY(two, 2, (SEXP a1, SEXP a2), (a1, a2))" %in% header
  )
  # Unchanged declarations leave the file alone.
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
  header <- readLines(file.path(pkg, "src", "entrypoints.h"))
  expect_true("#define JLBIND_ENTRIES" %in% header)
})
