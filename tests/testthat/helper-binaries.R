windows <- .Platform$OS.type == "windows"

# A .tar.gz of a fake pre-built library of version `version` of `pkg`, as
# build_library() writes it; returns its path.
fake_archive <- function(
  pkg = "a",
  version = "1.0",
  abi = .library_abi,
  salt = .salt(pkg),
  bundle = TRUE,
  cpu_target = "generic",
  env = parent.frame()
) {
  dir <- withr::local_tempdir(.local_envir = env)
  writeLines("not really a library", file.path(dir, .library_file()))
  write.dcf(
    data.frame(
      Package = pkg,
      Version = version,
      Module = toupper(pkg),
      Hash = "h"
    ),
    file.path(dir, "clients")
  )
  file.create(file.path(dir, "excluded"))
  write.dcf(
    data.frame(
      jlbind = "0.0.1",
      Julia = "1.14.0",
      Built = "2026-01-01 00:00:00 UTC",
      Trim = TRUE,
      Develop = "",
      CpuTarget = cpu_target,
      CPU = "",
      JuliaArgs = "",
      Bundle = bundle,
      Private = salt,
      ABI = abi
    ),
    file.path(dir, "build")
  )
  archive <- file.path(withr::local_tempdir(.local_envir = env), "lib.tar.gz")
  withr::with_dir(
    dir,
    utils::tar(archive, ".", compression = "gzip", tar = "internal")
  )
  archive
}
