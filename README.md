# jlbind

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
[Performance](https://bjarkehautop.github.io/jlbind/articles/performance.html)).

Several R packages using jlbind can be installed side by side: their Julia code
is compiled into one shared library.

## Installation

```r
# install.packages("pak")
pak::pak("BjarkeHautop/jlbind")
```

Building the shared library requires [Julia](https://julialang.org) >=
1.13. Installing jlbind does not itself build the library.

## Using a package built on jlbind

After installing or updating an R package that uses jlbind, build the shared
library:

```r
jlbind::install_backend()
```

This compiles the Julia code of every installed package that uses jlbind and may
take a few minutes. Run it again whenever you install or update one of them.

## Writing a package that uses jlbind

Set up a package with `jlbind::use_jlbind()`, then declare the Julia functions R
can call in the generated binding package under `inst/julia/`:

```julia
module MyPkgBindings

using JLBind

greet(name::String) = "Hello, " * name * "!"
@rcall greet(name::String)::String

end
```

Run `jlbind::update_entrypoints()`, and call the function from R:

```r
greet <- function(name) .Call(C_greet, name)
```

See [Writing a package that uses
jlbind](https://bjarkehautop.github.io/jlbind/articles/writing-clients.html) for
a full walkthrough.
