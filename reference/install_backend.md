# Build the Julia library

Compiles the Julia code of every installed package that uses jlbind into
one shared library, stored in `tools::R_user_dir("jlbind", "data")`. Run
this after you install or update one of those packages. You need Julia
1.13 or later. The first build downloads and compiles the Julia
dependencies, which can take a few minutes.

## Usage

``` r
install_backend(
  packages = NULL,
  julia = NULL,
  ask = interactive(),
  force = FALSE,
  update = FALSE,
  develop = NULL
)
```

## Arguments

- packages:

  Names of the installed packages to build. By default, every package
  listed by
  [`jlbind_clients()`](https://bjarkehautop.github.io/jlbind/reference/jlbind_clients.md).
  The others aren't bound.

- julia:

  Path to the `julia` executable. By default, the `JULIA` environment
  variable, or `julia` on the `PATH`.

- ask:

  If `TRUE`, ask before building. Defaults to
  [`interactive()`](https://rdrr.io/r/base/interactive.html).

- force:

  If `TRUE`, rebuild even if the library is up to date. Always on with
  `update` or `develop`.

- update:

  If `TRUE`, use the newest dependency versions instead of those in the
  packages' `Manifest.toml` files.

- develop:

  Paths to local Julia packages to use instead of their released
  versions.

## Value

The path to the library (invisibly), or `NULL` if there was nothing to
build.

## Details

All packages share one Julia environment. By default, the dependencies
get the versions in the first package's `Manifest.toml`. If two packages
conflict, the one listed later by
[`jlbind_clients()`](https://bjarkehautop.github.io/jlbind/reference/jlbind_clients.md)
is left out, and
[`check_backend()`](https://bjarkehautop.github.io/jlbind/reference/is_bound.md)
says why. See
[`vignette("jlbind")`](https://bjarkehautop.github.io/jlbind/articles/jlbind.md)
for details.

If a library is already loaded, restart R to use the new one. If the
Julia used for the build is updated or removed, rebuild with
`force = TRUE`.

## Examples

``` r
if (FALSE) { # \dontrun{
install_backend()

# With a local checkout of a Julia dependency
install_backend(develop = "~/dev/SomePackage.jl")

# Only two of the installed packages
install_backend(packages = c("pkgA", "pkgB"))
} # }
```
