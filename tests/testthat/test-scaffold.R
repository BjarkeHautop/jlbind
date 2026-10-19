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
  c_src <- readLines(file.path(pkg, "src", "jlbind.c"))
  expect_true("void R_init_my_pkg(DllInfo *dll)" %in% c_src)
  expect_true('#define JLBIND_PACKAGE "my.pkg"' %in% c_src)
  expect_false(any(grepl("{{", c_src, fixed = TRUE)))
  header <- readLines(file.path(pkg, "src", "entrypoints.h"))
  expect_true("    JLBIND_ENTRY(hello, 1, (SEXP a1), (a1))" %in% header)

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
  expect_equal(
    readLines(file.path(pkg, "NAMESPACE")),
    'useDynLib(my.pkg, .registration = TRUE, .fixes = "C_")'
  )
  expect_equal(readLines(file.path(pkg, ".Rbuildignore")), "^\\.jlbind$")
  expect_equal(readLines(file.path(pkg, ".gitignore")), ".jlbind/")

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
  r_code <- readLines(file.path(dir, "R", "jlbind.R"))
  expect_false(any(grepl("onLoad <-", r_code)))
  expect_true(any(grepl("@useDynLib hook", r_code)))
})

test_that("use_jlbind() refuses a package that registers routines itself", {
  dir <- withr::local_tempdir()
  writeLines(
    c("Package: own", "Version: 1.0", "Title: x"),
    file.path(dir, "DESCRIPTION")
  )
  dir.create(file.path(dir, "src"))
  writeLines(
    "void R_init_own(DllInfo *dll) {}",
    file.path(dir, "src", "init.c")
  )
  expect_error(
    suppressMessages(use_jlbind(dir)),
    "registers the package's routines"
  )
})

test_that("use_jlbind() makes jlbind.o depend on entrypoints.h", {
  pkg <- local_client()
  expect_equal(
    readLines(file.path(pkg, "src", "Makevars")),
    c(
      "all: $(SHLIB)",
      "",
      "# Added by jlbind::use_jlbind(): recompile jlbind.c whenever",
      "# jlbind::update_entrypoints() rewrites the header it includes.",
      "jlbind.o: entrypoints.h"
    )
  )
})

test_that("use_jlbind() adds its rule to existing Makevars files", {
  dir <- withr::local_tempdir()
  writeLines(
    c("Package: mk", "Version: 1.0", "Title: x"),
    file.path(dir, "DESCRIPTION")
  )
  src <- file.path(dir, "src")
  dir.create(src)
  writeLines("PKG_LIBS = -lm", file.path(src, "Makevars"))
  writeLines(
    c("all: $(SHLIB) extra", "extra:", "\techo hi"),
    file.path(src, "Makevars.win")
  )
  suppressMessages(use_jlbind(dir))

  makevars <- readLines(file.path(src, "Makevars"))
  # `all` comes before the rule, so it stays make's default target.
  expect_equal(makevars[1:3], c("all: $(SHLIB)", "", "PKG_LIBS = -lm"))
  expect_equal(makevars[[length(makevars)]], .makevars_rule)
  win <- readLines(file.path(src, "Makevars.win"))
  expect_equal(win[1:3], c("all: $(SHLIB) extra", "extra:", "\techo hi"))
  expect_equal(sum(win == .makevars_rule), 1L)
  expect_false(file.exists(file.path(src, "Makevars.ucrt")))

  # Running it again changes nothing.
  suppressMessages(use_jlbind(dir))
  expect_equal(readLines(file.path(src, "Makevars")), makevars)
  expect_equal(readLines(file.path(src, "Makevars.win")), win)
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

test_that("use_jlbind() leaves a roxygen NAMESPACE to roxygen", {
  dir <- withr::local_tempdir()
  writeLines(c("Package: rox", "Version: 1.0"), file.path(dir, "DESCRIPTION"))
  ns <- "# Generated by roxygen2: do not edit by hand"
  writeLines(ns, file.path(dir, "NAMESPACE"))
  expect_match(
    capture_messages(use_jlbind(dir)),
    "roxygenise",
    all = FALSE
  )
  expect_equal(readLines(file.path(dir, "NAMESPACE")), ns)
})

test_that("a client's binding package must exist and be named", {
  expect_error(.client_info(tempfile()), "No package found")
  dir <- withr::local_tempdir()
  expect_error(.binding_name(dir), "No Julia package")
  writeLines('uuid = "x"', file.path(dir, "Project.toml"))
  expect_error(.binding_name(dir), "has no `name`")
  expect_true(.parse_trim(" Yes ", "x"))
})
