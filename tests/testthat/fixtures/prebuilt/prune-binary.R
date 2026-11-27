# The tools/prune-binary.R of the test client in test-prebuilt.R: removes the
# runtime libraries the tiny hellojl doesn't use from its pre-built library, as
# in vignette("build-options", "jlbind"), and Julia's share directory.
function(dir) {
  keep <- c(
    "libjulia",
    "libjulia-internal",
    "libunwind",
    "libz",
    "libzstd",
    "libatomic",
    "libgcc_s",
    "libopenlibm",
    # The GCC runtime, which Windows lacks.
    if (.Platform$OS.type == "windows") {
      c("libgcc_s_seh", "libwinpthread", "libstdc++", "libssp")
    }
  )
  # A library's name without the salt of a private runtime, its extension
  # and its version: jl0f5ce2_libjulia.so.1.14 is libjulia.
  base <- function(file) {
    file <- sub("^jl[0-9a-f]{6}_", "", file)
    file <- sub("\\.(so|dylib|dll)(\\..*)?$", "", file)
    sub("([-.][0-9]+)+$", "", file)
  }
  unlink(file.path(dir, "jlbind-bundle", "share"), recursive = TRUE)
  libs <- list.files(
    dir,
    "\\.(so|dylib|dll)(\\.[0-9.]+)?$",
    recursive = TRUE,
    full.names = TRUE
  )
  libs <- libs[!grepl("^jlbind\\.", basename(libs))]
  unlink(libs[!base(basename(libs)) %in% keep])
}
