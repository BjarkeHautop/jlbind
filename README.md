# jlbind <picture><source media="(prefers-color-scheme: dark)" srcset="man/figures/logo.png" /><img src="man/figures/logo-light.png" align="right" height="139" alt="jlbind logo" /></picture>

<!-- badges: start -->
[![R-CMD-check](https://github.com/BjarkeHautop/jlbind/actions/workflows/R-CMD-check.yaml/badge.svg)](https://github.com/BjarkeHautop/jlbind/actions/workflows/R-CMD-check.yaml)
[![Codecov test
coverage](https://codecov.io/gh/BjarkeHautop/jlbind/graph/badge.svg)](https://app.codecov.io/gh/BjarkeHautop/jlbind)
<!-- badges: end -->

Call Julia code from R without starting a Julia session.

jlbind compiles Julia code into a shared library with
[JuliaC.jl](https://github.com/JuliaLang/JuliaC.jl) (by default with
`--trim=safe`), and R calls it through R's official C API. Thus, there is almost
no overhead (see
[Performance](https://bjarkehautop.github.io/jlbind/vignettes/articles/performance.html)).

## Installation

```r
# install.packages("pak")
pak::pak("BjarkeHautop/jlbind")
```

Building the shared library requires [Julia](https://julialang.org) >= 1.13.
Installing jlbind does not itself build the library.

Julia 1.14 or later is recommended: Julia 1.13 can compile a library that
crashes as it loads. This happens when every compiled specialization of a method
has a type parameter bounded by a `Union` (`where {T<:Union{...}}`): trimming
then overwrites the image's shared empty `Memory{Any}`. It is fixed in
[JuliaLang/julia#63664](https://github.com/JuliaLang/julia/pull/63664).

## Using a package built on jlbind

After installing or updating an R package that uses jlbind, build the shared
library:

```r
jlbind::install_library()
```

This compiles the Julia code of every installed package that uses jlbind and may
take a few minutes. Run it again whenever you install or update one of them.

See [Using packages built on
jlbind](https://bjarkehautop.github.io/jlbind/vignettes/using-clients.html) for
threads, troubleshooting and what to do when packages conflict, and [Build
options](https://bjarkehautop.github.io/jlbind/vignettes/build-options.html) for
CPU targets and libraries for computers without Julia.

## Writing a package that uses jlbind

Set up a package with `jlbind::use_jlbind()`, then declare the Julia functions R
can call in the generated binding package under `inst/julia/`:

```julia
module MyPkgBindings

using JLBind

greet(name) = "Hello, " * name * "!"
@rcall greet(name::String)::String

end # module MyPkgBindings
```

Run `jlbind::update_entrypoints()`, which generates the R function `greet(name)`
that calls it.

See [Get started with
jlbind](https://bjarkehautop.github.io/jlbind/vignettes/jlbind.html) for a
walkthrough, and [Writing
bindings](https://bjarkehautop.github.io/jlbind/vignettes/technical-details.html)
for types, errors and compilation constraints.

## Packages using jlbind

- [CausalStructures](https://bjarkehautop.github.io/CausalStructures/): causal
  graphs (DAGs, CPDAGs, PAGs, ...) and identification, from
  [CausalStructures.jl](https://github.com/BjarkeHautop/CausalStructures.jl).
  Its [binding
  package](https://github.com/BjarkeHautop/CausalStructures/blob/main/inst/julia/src/csjl.jl)
  shows some advanced usage, such as:
  - R holds graphs of an abstract type (`RRef{CausalGraph}`), and each function
    branches on the concrete class (DAG, PAG, ...) with `@narrow`.
  - Graphs survive `saveRDS()`/`readRDS()` via ALTREP (`r_saved_by` and
    `r_restore`).
  - Large results (edge lists, data frames) are built in place through R's C
    API.

Using jlbind for your package? Feel free to open a pull request adding it to
this list.

## Contributing

Contributions of all kinds are very welcome! The [contributing
guide](https://github.com/BjarkeHautop/jlbind/blob/main/.github/CONTRIBUTING.md)
covers how to test and document changes, and our policy on using LLMs.
