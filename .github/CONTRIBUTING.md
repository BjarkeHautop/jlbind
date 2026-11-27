# Contributing to jlbind

Thanks for helping out! This page covers what you need to work on jlbind itself.

You may use LLMs, but please write issue and PR descriptions in your own words.
If you submit a PR, you should understand the code you're contributing.

## Tests

The tests that compile a library are slow and skipped unless you opt in with
environment variables:

  | Variable                  | Runs                                                                                                                                                                             |
  | ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
  | `JLBIND_TEST_BUILD=true`  | `test-integration.R`: installs the clients in `tests/clients/` into a temporary library, compiles them into one library and calls them from fresh R processes (a minute or more) |
  | `JLBIND_TEST_NOTRIM=true` | builds a copy of `hellojl` with `Config/jlbind/trim: false`, an untrimmed \~200 MB library                                                                                       |

```sh
JLBIND_TEST_BUILD=true Rscript -e 'devtools::test(filter = "integration")'
```

The JLBind Julia package has its own tests in `inst/julia/JLBind/test/`. They
run in a Julia session with R embedded by
[RCall](https://github.com/JuliaInterop/RCall.jl), so they need R.

```sh
julia --project=inst/julia/JLBind -e 'using Pkg; Pkg.test()'
```

On Linux, R may fail to start inside Julia without `R_HOME/lib` on the library
path, and exit without printing why. Run the tests with
`LD_LIBRARY_PATH="$(R RHOME)/lib"` set.

Each test client in `tests/clients/` covers one area:

- `hellojl` is a hello world.
- `convertjl` has the conversions between R and Julia and their errors.
- `counterjl` has Julia objects held by R.

The clients are scaffolded output: their `R/zzz.R` and `R/jlbind-wrappers.R`
correspond to `inst/templates/` and `update_entrypoints()`, and their
`NAMESPACE` exports every entrypoint. When you change a template or the wrapper
generator, update the test clients to match.

## Code style and git hooks

This repo uses the following hooks:

- [panache](https://github.com/jolars/panache) formats and lints Markdown and
  Quarto files,
- [air](https://github.com/posit-dev/air) formats R code,
- [jarl](https://github.com/etiennebacher/jarl) lints R code,
- [JuliaFormatter](https://github.com/domluna/JuliaFormatter.jl) formats Julia
  code,
- a check that the roxygen documentation is up to date,
- a check that the JLBind reference is up to date,
- [JETLS](https://github.com/aviatesk/JETLS.jl) checks JLBind for errors such as
  calls with no matching method (skipped if the `jetls` app isn't installed).

## Documentation and website

The guides are the vignettes in `vignettes/`. `vignettes/articles/` holds two
website-only articles:

- `performance.qmd`, whose data comes from `performance/benchmark.R`.

- `jlbind-reference.qmd`, the reference of the JLBind Julia package, which is
  generated from its docstrings. Every public JLBind name needs a docstring and
  an entry in the `SECTIONS` of `jlbind-reference/build.jl`. Regenerate it with

  ```sh
  julia --project=inst/julia/JLBind vignettes/articles/jlbind-reference/build.jl
  ```

The website is built with
[quartodown](https://github.com/BjarkeHautop/quartodown), which needs
[Quarto](https://quarto.org):

```r
quartodown::build_site()
```

`_quartodown/_quartodown.yml` lays out the navbar and groups the reference
index, so add new exported functions and vignettes there.
