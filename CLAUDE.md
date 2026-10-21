# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## What this is

jlbind is an R package that lets other R packages ("clients") call Julia code
compiled ahead of time with `juliac --trim=safe`, with no Julia session at run
time. An R process can host only one compiled Julia image, so jlbind compiles
the binding packages of *every* installed client into one shared library that
all of them bind to. `vignettes/jlbind.qmd` (Get started: writing a client) and
`vignettes/using-clients.qmd` (installing and using clients) are the user-facing
guides (rendered with Quarto); keep them in sync with user-visible behavior.
`vignettes/articles/performance.qmd` is a website-only article whose data comes
from `vignettes/articles/performance/benchmark.R`.

The website is built with
[quartodown](https://github.com/BjarkeHautop/quartodown). Build it with
`quartodown::build_site()` (output in `docs/`). `_quartodown/_quartodown.yml`
groups the reference index; new functions must be added there. The navbar is
generated: `jlbind.qmd` is "Get started" and every other vignette, including
`vignettes/articles/`, goes under "Articles". `_quarto/` is the Quarto project
generated on every build and is gitignored.

## Commands

```r
devtools::document() # regenerate man/ and NAMESPACE from roxygen
devtools::test() # unit tests (no Julia needed)
devtools::test(filter = "entrypoints") # one test file (test-entrypoints.R)
devtools::check() # R CMD check
```

Git hooks are managed with [prek](https://github.com/j178/prek) from
`.pre-commit-config.yaml`: panache (Markdown), air (R formatting), jarl (R lint)
and a roxygen-up-to-date check. Run them with `prek run --all-files`. Tests run
in the package namespace, so call internal functions directly rather than via
`jlbind:::` (jarl flags it).

The integration test (`tests/testthat/test-integration.R`) installs the two
clients in `tests/clients/` into a temp library, compiles them into one library
and calls them from a fresh R process. It takes a minute or more and only runs
with Julia >= 1.13 and `JLBIND_TEST_BUILD=true`:

```sh
JLBIND_TEST_BUILD=true Rscript -e 'devtools::test(filter = "integration")'
```

A second integration test builds a copy of `hellojl` with
`Config/jlbind/trim: false` (an untrimmed, \~200 MB library); it runs only with
`JLBIND_TEST_NOTRIM=true`.

jlbind needs Julia >= 1.13, but use nightly until 1.14 is released: Julia 1.13
sometimes compile a `--trim` library that crashes as the runtime initializes
(`jl_egal_` in `lookup_leafcache`, from `jl_module_run_initializer`): pruning
swaps the shared empty `Memory{Any}` for a 32-byte index when a method's
specializations all have signatures without a type hash, such as from a type
variable bounded by a `Union` (`where {T<:Union{...}}`). It is fixed on master
by [JuliaLang/julia#63664](https://github.com/JuliaLang/julia/pull/63664), not
yet backported to 1.13. The repository has a juliaup override
(`juliaup override set nightly`), so `julia` run in it, and so jlbind's builds,
use nightly; check with `juliaup override status`. A Julia run from outside the
repository (e.g. an R session whose working directory is elsewhere) still gets
the default channel.

Environment variables: `JULIA` (Julia binary to use), `JLBIND_LIBRARY` (load
this library instead of the one `install_library()` builds, or the one
`build_library()` writes to a `load_all()`ed client's `.jlbind/`),
`JULIA_NUM_THREADS`.

CI (`.github/workflows/R-CMD-check.yaml`) runs R CMD check with Julia nightly on
Linux/Windows/macOS, all with the integration test enabled (the Linux job also
sets `JLBIND_TEST_NOTRIM`), and once on Linux without Julia, which is what CRAN
sees — everything except the integration test must pass without Julia.
`test-coverage.yaml` runs covr with Julia nightly and `JLBIND_TEST_BUILD=true`
and uploads to Codecov; `altdoc.yaml` builds and deploys the site.

## Architecture

Three layers, spread across R, Julia and C:

- **`inst/julia/JLBind/`** — Julia package that clients' binding packages depend
  on: R C API via `ccall` (`rapi.jl`), `from_sexp`/`to_sexp` conversions
  (`convert.jl`), `RRef{T}` external-pointer registry (`refs.jl`), and the
  `@rcall` macro (`rcall.jl`) that exports `<Module>_<f>_<nargs>` as a
  `@ccallable`, returning errors as a `jlbind_error` character vector rather
  than unwinding. The argument count in the name makes a client whose shim
  disagrees with the library fail to bind rather than crash. `set_threads.c` is
  compiled into the library and called via `.C`. JLBind is not registered:
  builds `Pkg.develop` the copy shipped in the installed R package.
- **`inst/julia/build.jl`** — the compile step, invoked by the R side. It copies
  everything to writable scratch dirs, generates a `JLBindImage` package
  importing JLBind and every binding package, seeds dependencies from the first
  client's `Manifest.toml` (falling back to `[compat]` resolution), and compiles
  with JuliaC in a separate environment.
- **R side (`R/`)** — `library.R`: `install_library()` / `build_library()`
  (finds clients, runs `build.jl`, stores the library under
  `R_user_dir("jlbind", "data")/library/` with the client versions and binding
  package hashes (`.binding_hash()`) it was built from, so it is rebuilt when a
  client's Julia code changes without a version bump). `clients.R`: client
  discovery via the `Config/jlbind` DESCRIPTION field. `runtime.R`:
  `bind_client(pkg)` called from a client's `.onLoad`, loads the library once,
  sets threads, binds a client only if the library was built from its installed
  version. `sitrep.R`: `jlbind_sitrep()`, a report on Julia, the library and
  each client that works before a library has loaded. `scaffold.R`:
  `use_jlbind()` and `update_entrypoints()`, which scans `@rcall` declarations
  (with comments/strings blanked, so they must be literal top-level `@rcall`s)
  and writes `src/entrypoints.h`. `julia.R`: locating Julia.

Each client carries a generated C shim: `src/jlbind.c` (from
`inst/templates/init.c`) plus `src/entrypoints.h` (an X-macro list of
`JLBIND_ENTRY(name, nargs, params, args)`). The shim registers each routine
itself and forwards to the combined library through function pointers resolved
when jlbind calls the client's `jlbind_bind` routine. `src/Makevars` (from
`.set_makevars()`) makes `jlbind.o` depend on `entrypoints.h`, since make would
otherwise reuse a stale `jlbind.o` after `update_entrypoints()`.

The test clients in `tests/clients/{hellojl,counterjl}` are scaffolded output:
their `src/jlbind.c`, `src/entrypoints.h`, `src/Makevars` and `R/jlbind.R`
correspond to `inst/templates/` and `update_entrypoints()`. When changing a
template or the header generator, update the test clients to match.

## Constraints to keep in mind

- Everything in the library is compiled with `--trim=safe`, so every Julia call
  must be statically resolvable. A function receiving an abstract `RRef{T}` must
  take it as `@nospecialize(x::T)` and branch on concrete types; `Core.invoke`
  is not accepted by trim verification (Julia 1.13).
- `@R(sym)` must name `R.dll` on Windows; Windows builds record `julia_bindir`
  so R can find the Julia runtime before loading the DLL.
- Never write into an installed package directory; builds work on scratch
  copies.
- `experiments/two-libs/` (excluded from the build) demonstrates why two juliac
  libraries cannot coexist in one process.
