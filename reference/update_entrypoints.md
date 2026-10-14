# Update the list of Julia functions R can call

Finds the `@rcall` declarations in the package's Julia binding package
and writes them to `src/entrypoints.h`. From that, `src/jlbind.c`
registers a routine `C_<name>` for each one. Run this whenever you add
or remove an `@rcall`, or change its arguments, much like
[`Rcpp::compileAttributes()`](https://rdrr.io/pkg/Rcpp/man/compileAttributes.html).

## Usage

``` r
update_entrypoints(path = ".")
```

## Arguments

- path:

  Path to the package sources.

## Value

Invisibly, a data frame of the entrypoints with the columns `name` and
`nargs`.

## Examples

``` r
# A package set up with use_jlbind() in a temporary directory
pkg <- file.path(tempdir(), "addpkg")
dir.create(pkg)
writeLines(
  c(
    "Package: addpkg",
    "Title: Demo",
    "Version: 0.1.0",
    "Description: Demo.",
    "License: MIT"
  ),
  file.path(pkg, "DESCRIPTION")
)
use_jlbind(pkg)
#> Created the binding package addpkgBindings in /tmp/RtmpP4r2qA/addpkg/inst/julia.
#> Wrote /tmp/RtmpP4r2qA/addpkg/src/entrypoints.h (1 entrypoints).

# Add an entrypoint to the binding package, before its closing `end`
file <- file.path(pkg, "inst/julia/src/addpkgBindings.jl")
code <- readLines(file)
last <- max(which(code == "end"))
code <- append(
  code,
  c(
    "add(x::Float64, y::Float64) = x + y",
    "@rcall add(x::Float64, y::Float64)::Float64",
    ""
  ),
  after = last - 1L
)
writeLines(code, file)

update_entrypoints(pkg)
#> Wrote /tmp/RtmpP4r2qA/addpkg/src/entrypoints.h (2 entrypoints).
# The package now calls it as .Call(C_add, x, y)
```
