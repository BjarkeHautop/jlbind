# List the packages that use jlbind

Lists the installed packages that
[`install_backend()`](https://bjarkehautop.github.io/jlbind/reference/install_backend.md)
will compile. A package uses jlbind if its `DESCRIPTION` has a
`Config/jlbind` field. If a package is installed in more than one
library, the copy that
[`library()`](https://rdrr.io/r/base/library.html) would load is the one
listed.

## Usage

``` r
jlbind_clients(lib.loc = NULL)
```

## Arguments

- lib.loc:

  Library paths to search. Defaults to
  [`.libPaths()`](https://rdrr.io/r/base/libPaths.html).

## Value

A data frame with one row per package and the columns `package`,
`version`, `module` (its Julia binding package), `path` (where the
binding package is) and `trim` (`FALSE` if it sets
`Config/jlbind/trim: false`).

## Examples

``` r
jlbind_clients()
#> [1] package version module  path    trim   
#> <0 rows> (or 0-length row.names)
```
