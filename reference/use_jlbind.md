# Set up a package to use jlbind

Adds what a package needs to call Julia code through jlbind:

## Usage

``` r
use_jlbind(path = ".", module = NULL, dir = "julia")
```

## Arguments

- path:

  Path to the package sources.

- module:

  Name of the Julia binding package. Defaults to the package name
  followed by `Bindings`. It must be unique across all packages that use
  jlbind, since they're all compiled into one library.

- dir:

  Directory under `inst/` for the binding package.

## Value

`path`, invisibly.

## Details

- A Julia binding package in `inst/<dir>`, with one example function,
  `hello()`. An existing binding package is left alone.

- The C code that registers the package's routines: `src/jlbind.c` and
  `src/entrypoints.h` (written by
  [`update_entrypoints()`](https://bjarkehautop.github.io/jlbind/reference/update_entrypoints.md)).

- `R/jlbind.R`, with an `.onLoad()` that calls
  [`bind()`](https://bjarkehautop.github.io/jlbind/reference/bind.md),
  and the roxygen tag for `useDynLib()`. If the package already has an
  `.onLoad()`, add `jlbind::bind(pkgname)` to it yourself.

- The `Config/jlbind` and `Imports: jlbind` fields in `DESCRIPTION`.

- `.jlbind/`, where
  [`build_library()`](https://bjarkehautop.github.io/jlbind/reference/build_library.md)
  writes a library for development, in `.Rbuildignore` and `.gitignore`.

It's safe to run again. Afterwards, call each Julia function `f` from R
with `.Call(C_f, ...)`.

## Examples

``` r
# A new package in a temporary directory
pkg <- file.path(tempdir(), "mypkg")
dir.create(pkg)
writeLines(
  c(
    "Package: mypkg",
    "Title: Demo",
    "Version: 0.1.0",
    "Description: Demo.",
    "License: MIT"
  ),
  file.path(pkg, "DESCRIPTION")
)

use_jlbind(pkg)
#> Created the binding package mypkgBindings in /tmp/RtmpP4r2qA/mypkg/inst/julia.
#> Wrote /tmp/RtmpP4r2qA/mypkg/src/entrypoints.h (1 entrypoints).
list.files(pkg, recursive = TRUE)
#> [1] "DESCRIPTION"                     "NAMESPACE"                      
#> [3] "R/jlbind.R"                      "inst/julia/Project.toml"        
#> [5] "inst/julia/src/mypkgBindings.jl" "src/entrypoints.h"              
#> [7] "src/jlbind.c"                   

# The Julia binding package, with its example entrypoint
writeLines(readLines(file.path(pkg, "inst/julia/src/mypkgBindings.jl")))
#> """
#>     mypkgBindings
#> 
#> The R entrypoints of the R package mypkg. Each `@rcall` declaration
#> exports a function R calls as `.Call(C_<name>, ...)`; after changing them, run
#> `jlbind::update_entrypoints()` to regenerate `src/entrypoints.h`.
#> """
#> module mypkgBindings
#> 
#> using JLBind
#> 
#> hello(name::String) = "Hello, " * name * ", from Julia!"
#> 
#> @rcall hello(name::String)::String
#> 
#> end
```
