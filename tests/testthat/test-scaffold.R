test_that("use_jlbind() sets up a package", {
  pkg <- local_client("my.pkg", module = NULL)
  expect_true(file.exists(file.path(
    pkg,
    "inst",
    "julia",
    "src",
    "mypkgBindings.jl"
  )))
  expect_equal(
    .binding_name(file.path(pkg, "inst", "julia")),
    "mypkgBindings"
  )
  # It needs no C code.
  expect_false(dir.exists(file.path(pkg, "src")))
  wrappers <- readLines(file.path(pkg, "R", "jlbind-wrappers.R"))
  expect_true('.jlbind_module <- "mypkgBindings"' %in% wrappers)
  expect_true('  "hello"' %in% wrappers)

  desc <- read.dcf(file.path(pkg, "DESCRIPTION"))
  expect_equal(desc[, "Config/jlbind"], c("Config/jlbind" = "julia"))
  expect_equal(
    trimws(strsplit(desc[, "Imports"], ",")[[1]]),
    c("stats", "jlbind")
  )
  expect_true(any(grepl(
    "jlbind::bind_client(pkgname)",
    readLines(file.path(pkg, "R", "jlbind.R")),
    fixed = TRUE
  )))
  expect_false(file.exists(file.path(pkg, "NAMESPACE")))
  expect_equal(readLines(file.path(pkg, ".Rbuildignore")), "^\\.jlbind$")
  expect_equal(readLines(file.path(pkg, ".gitignore")), ".jlbind/")

  project <- readLines(file.path(pkg, "inst", "julia", "Project.toml"))
  expect_true(any(grepl(
    paste0('rev = "', .jlbind_rev(), '"'),
    project[grepl("^JLBind = \\{url", project)],
    fixed = TRUE
  )))

  info <- .client_info(pkg)
  expect_equal(info$package, "my.pkg")
  expect_equal(info$module, "mypkgBindings")
  expect_equal(info$path, file.path(normalizePath(pkg), "inst", "julia"))
})

test_that("use_jlbind() is idempotent and keeps an existing binding package", {
  pkg <- local_client()
  files <- list.files(
    pkg,
    recursive = TRUE,
    all.files = TRUE,
    full.names = TRUE
  )
  before <- tools::md5sum(files)
  expect_message(
    use_jlbind(pkg, module = "Other"),
    "Using the binding package DemoBindings"
  )
  expect_equal(tools::md5sum(files), before)
})

test_that("use_jlbind() leaves an existing .onLoad() to the package", {
  dir <- withr::local_tempdir()
  writeLines(
    c("Package: hook", "Version: 1.0", "Title: x"),
    file.path(dir, "DESCRIPTION")
  )
  dir.create(file.path(dir, "R"))
  writeLines(
    ".onLoad <- function(libname, pkgname) NULL",
    file.path(dir, "R", "zzz.R")
  )
  expect_match(capture_messages(use_jlbind(dir)), "has an .onLoad", all = FALSE)
  expect_false(file.exists(file.path(dir, "R", "jlbind.R")))
})

test_that("use_jlbind() leaves a package's own C code alone", {
  dir <- withr::local_tempdir()
  writeLines(
    c("Package: own", "Version: 1.0", "Title: x"),
    file.path(dir, "DESCRIPTION")
  )
  dir.create(file.path(dir, "src"))
  init <- file.path(dir, "src", "init.c")
  writeLines("void R_init_own(DllInfo *dll) {}", init)
  suppressMessages(use_jlbind(dir))
  expect_equal(readLines(init), "void R_init_own(DllInfo *dll) {}")
})

test_that("a package without the DESCRIPTION field is not a client", {
  dir <- withr::local_tempdir()
  writeLines(c("Package: plain", "Version: 1.0"), file.path(dir, "DESCRIPTION"))
  expect_error(.client_info(dir), "does not use jlbind")
})

test_that("a client is trimmed unless Config/jlbind/trim says otherwise", {
  pkg <- local_client()
  expect_true(.client_info(pkg)$trim)
  desc <- file.path(pkg, "DESCRIPTION")
  lines <- readLines(desc)
  writeLines(c(lines, "Config/jlbind/trim: false"), desc)
  expect_false(.client_info(pkg)$trim)
  expect_false(.client_table(list(.client_info(pkg)))$trim)
  writeLines(c(lines, "Config/jlbind/trim: maybe"), desc)
  expect_error(.client_info(pkg), "must be true or false")
})

test_that("UUIDs are version 3 and derived from the module name", {
  u <- .uuid3("FooBindings")
  expect_match(
    u,
    "^[0-9a-f]{8}-[0-9a-f]{4}-3[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
  )
  expect_identical(.uuid3("FooBindings"), u)
  expect_false(.uuid3("BarBindings") == u)
})

test_that("use_jlbind() needs a package and a valid module name", {
  expect_error(use_jlbind(withr::local_tempdir()), "No package found")
  dir <- withr::local_tempdir()
  writeLines(c("Package: bad", "Version: 1.0"), file.path(dir, "DESCRIPTION"))
  expect_error(use_jlbind(dir, module = "1Bad"), "valid Julia package name")
})

test_that("use_jlbind_ci() writes a workflow that builds the library", {
  expect_error(use_jlbind_ci(withr::local_tempdir()), "No package found")
  pkg <- local_client()
  expect_message(file <- use_jlbind_ci(pkg), "Wrote")
  expect_equal(file, file.path(pkg, ".github", "workflows", "R-CMD-check.yaml"))
  workflow <- readLines(file)
  expect_true(any(grepl("jlbind::build_library()", workflow, fixed = TRUE)))
  expect_true(any(grepl("JLBIND_LIBRARY=", workflow, fixed = TRUE)))
  expect_true(any(grepl("julia: ''", workflow, fixed = TRUE)))
  expect_true("^\\.github$" %in% readLines(file.path(pkg, ".Rbuildignore")))

  writeLines("mine", file)
  expect_error(use_jlbind_ci(pkg), "overwrite = TRUE")
  expect_equal(readLines(file), "mine")
  expect_message(use_jlbind_ci(pkg, overwrite = TRUE), "Wrote")
  expect_equal(readLines(file), workflow)
})

test_that("a client's binding package must exist and be named", {
  expect_error(.client_info(tempfile()), "No package found")
  dir <- withr::local_tempdir()
  expect_error(.binding_name(dir), "No Julia package")
  writeLines('uuid = "x"', file.path(dir, "Project.toml"))
  expect_error(.binding_name(dir), "has no `name`")
  expect_true(.parse_trim(" Yes ", "x"))
})

test_that("[sources] names jlbind's release tag, or main in development", {
  expect_equal(.jlbind_rev("0.2.1"), "v0.2.1")
  expect_equal(.jlbind_rev("1.0.0.1"), "v1.0.0")
  expect_equal(.jlbind_rev("0.0.0.9000"), "main")
  expect_equal(.jlbind_rev("0.2.1.9001"), "main")
})
