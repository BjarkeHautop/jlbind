# Bind a package to the Julia library

Call this from the `.onLoad()` of a package that uses jlbind;
[`use_jlbind()`](https://bjarkehautop.github.io/jlbind/reference/use_jlbind.md)
sets that up. The first call loads the compiled library, and each call
binds one package's routines to it. If the library is missing or was
built from another version of the package, the package isn't bound and
its functions give an error;
[`check_backend()`](https://bjarkehautop.github.io/jlbind/reference/is_bound.md)
says why.

## Usage

``` r
bind(pkg)
```

## Arguments

- pkg:

  The package name.

## Value

Invisibly, `TRUE` if the package is bound and `FALSE` if not.

## Details

The library is the one from
[`install_backend()`](https://bjarkehautop.github.io/jlbind/reference/install_backend.md),
unless `JLBIND_LIBRARY` names another, or the first package bound was
loaded with
[`pkgload::load_all()`](https://pkgload.r-lib.org/reference/load_all.html)
and has one from
[`build_library()`](https://bjarkehautop.github.io/jlbind/reference/build_library.md).

To run Julia with more threads, set `JULIA_NUM_THREADS` (a number or
`"auto"`) before loading the first package that uses jlbind.

## Examples

``` r
if (FALSE) { # \dontrun{
# In a package's R/jlbind.R, as use_jlbind() writes it
.onLoad <- function(libname, pkgname) {
  jlbind::bind(pkgname)
}
} # }
```
