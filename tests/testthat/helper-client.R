# A package's sources in a temporary directory, set up with use_jlbind().
local_client <- function(
  name = "demo",
  module = "DemoBindings",
  env = parent.frame()
) {
  dir <- withr::local_tempdir(.local_envir = env)
  path <- file.path(dir, name)
  dir.create(path)
  writeLines(
    c(
      paste0("Package: ", name),
      "Title: Demo",
      "Version: 0.1.0",
      "Description: Demo.",
      "License: MIT",
      "Imports:",
      "    stats"
    ),
    file.path(path, "DESCRIPTION")
  )
  suppressMessages(use_jlbind(path, module = module))
  path
}
