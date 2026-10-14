# Build a Julia library from specific packages

Like
[`install_backend()`](https://bjarkehautop.github.io/jlbind/reference/install_backend.md),
but compiles only `packages` and writes the library to `out`, for
package development. By default, it builds the package in the working
directory into its `.jlbind/` directory, which `devtools::load_all()`
then uses instead of the library from
[`install_backend()`](https://bjarkehautop.github.io/jlbind/reference/install_backend.md).
To use a library written elsewhere, set `JLBIND_LIBRARY` to its path
before loading the package.

## Usage

``` r
build_library(
  packages = ".",
  out = NULL,
  julia = NULL,
  update = FALSE,
  develop = NULL
)
```

## Arguments

- packages:

  Names of installed packages, or paths to package sources or installed
  packages.

- out:

  Directory to write the library to. Defaults to `.jlbind/` in the
  sources of `packages`, which must then be a single source directory.

- julia:

  Path to the `julia` executable. By default, the `JULIA` environment
  variable, or `julia` on the `PATH`.

- update:

  If `TRUE`, use the newest dependency versions instead of those in the
  packages' `Manifest.toml` files.

- develop:

  Paths to local Julia packages to use instead of their released
  versions.

## Value

The path to the library, invisibly.

## Examples

``` r
if (FALSE) { # \dontrun{
# In the sources of a package that uses jlbind
build_library()
devtools::load_all()

# Several packages, used through JLBIND_LIBRARY
lib <- build_library(c("pkg1", "pkg2"), "jlbind-lib")
Sys.setenv(JLBIND_LIBRARY = lib)
} # }
```
