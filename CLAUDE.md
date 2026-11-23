# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with
code in this repository.

## What this is

jlbind is an R package that lets other R packages ("clients") call Julia code
compiled ahead of time with `juliac --trim=safe`, with no Julia session at run
time. An R process can host only one compiled Julia image, so jlbind compiles
the binding packages of *every* installed client into one shared library that
all of them bind to. `vignettes/jlbind.qmd` (Get started: a short walkthrough of
writing a client), `vignettes/technical-details.qmd` ("Writing bindings": what
Get started leaves out: types, errors, trimming, development libraries),
`vignettes/using-clients.qmd` (installing and using clients),
`vignettes/libraries.qmd` (shared, private and separate libraries: what each
gives and costs, and when to use which) and `vignettes/build-options.qmd` (build
options, CPU targets, bundled runtimes and their sizes) are the user-facing
guides (rendered with Quarto); keep them in sync with user-visible behavior.
`vignettes/articles/performance.qmd` is a website-only article whose data comes
from `vignettes/articles/performance/benchmark.R`.
`vignettes/articles/jlbind-reference.qmd` (website-only) is generated from
JLBind's docstrings by `vignettes/articles/jlbind-reference/build.jl` (run with
`julia --project=inst/julia/JLBind`; `--check` is a pre-commit hook). Every
public JLBind name needs a docstring and an entry in its `SECTIONS`; names
sharing an entry share one docstring (`@doc (@doc a) b`).

The website is built with
[quartodown](https://github.com/BjarkeHautop/quartodown). Build it with
`quartodown::build_site()` (output in `docs/`). `_quartodown/_quartodown.yml`
groups the reference index; new functions must be added there. It also lays out
the navbar: `jlbind.qmd` is "Get started", "Reference" is a menu of the R
functions and the JLBind reference, and "Articles" lists the other vignettes, so
a new vignette must be added there (`build_site()` warns about one that isn't).
`_quarto/` is the Quarto project generated on every build and is gitignored.

## Commands

`.github/CONTRIBUTING.md` covers tests, hooks and the website for human
contributors; keep it in sync with this section.

```r
devtools::document() # regenerate man/ and NAMESPACE from roxygen
devtools::test() # unit tests (no Julia needed)
devtools::test(filter = "entrypoints") # one test file (test-entrypoints.R)
devtools::check() # R CMD check
```

Git hooks are managed with [prek](https://github.com/j178/prek) from
`.pre-commit-config.yaml`: panache (Markdown), air (R formatting), jarl (R
lint), roxygen- and JLBind-reference-up-to-date checks, and JETLS
(`jetls check inst/julia/JLBind/src/JLBind.jl`, configured in
`.JETLSConfig.toml`). Run them with `prek run --all-files`. Tests run in the
package namespace, so call internal functions directly rather than via
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

jlbind needs Julia >= 1.13, but use 1.14 (its prereleases until it is out):
Julia 1.13 sometimes compile a `--trim` library that crashes as the runtime
initializes (`jl_egal_` in `lookup_leafcache`, from
`jl_module_run_initializer`): pruning swaps the shared empty `Memory{Any}` for a
32-byte index when a method's specializations all have signatures without a type
hash, such as from a type variable bounded by a `Union`
(`where {T<:Union{...}}`). It is fixed on master by
[JuliaLang/julia#63664](https://github.com/JuliaLang/julia/pull/63664), which
1.14.0-beta1 includes but 1.13 does not yet.

Environment variables: `JULIA` (Julia binary to use), `JLBIND_LIBRARY` (load
this library instead of the one `install_library()` builds, or the one
`build_library()` writes to a `load_all()`ed client's `.jlbind/`),
`JULIA_NUM_THREADS`, `JULIA_CPU_TARGET` (the default `cpu_target` of builds,
else `"native"`), `JLBIND_JULIA_ARGS` (the default `julia_args` of builds, split
at spaces).

CI (`.github/workflows/R-CMD-check.yaml`) runs R CMD check with Julia 1.14 on
Linux/Windows, both with the integration test enabled (the Linux job also sets
`JLBIND_TEST_NOTRIM`), and once on Linux without Julia, which is what CRAN sees
— everything except the integration test must pass without Julia.
`test-coverage.yaml` runs covr with Julia 1.14 and `JLBIND_TEST_BUILD=true` and
uploads to Codecov; `quartodown.yaml` builds the site and deploys it from
`main`.

## Architecture

Three layers, spread across R, Julia and C:

- **`inst/julia/JLBind/`** — Julia package that clients' binding packages depend
  on: R C API via `ccall` (`rapi.jl`), `from_sexp`/`to_sexp` conversions
  (`convert.jl`), `RRef{T}` external-pointer registry (`refs.jl`), and the
  `@rcall` macro (`rcall.jl`) that exports `jlbind<n>_<Module>_<f>` (`n` the
  length of the module name, so names can't collide) as a `@ccallable` with the
  signature `SEXP f(SEXP *args, int n)`, checking `n` against the declaration
  and returning errors as a `jlbind_error` character vector rather than
  unwinding. `set_threads.c` is compiled into the library and called from
  `jlbind_set_threads()` in `src/call.c`. JLBind is not registered: builds
  `Pkg.develop` the copy shipped in the installed R package.
- **`inst/julia/build.jl`** — the compile step, invoked by the R side. It copies
  everything to writable scratch dirs, generates a `JLBindImage` package
  importing JLBind and every binding package, seeds dependencies from the first
  client's `Manifest.toml` (falling back to `[compat]` resolution), and compiles
  with JuliaC in a separate environment. With `bundle = TRUE` it also copies the
  Julia runtime into `jlbind-bundle/` next to the library, found through a
  relative RUNPATH (on Windows, `.add_julia_bindir()` puts it on the PATH while
  the library loads). `--privatize=<salt>` (from `.salt()`) also has JuliaC
  rename the bundled runtime's symbols, so the library loads alongside others
  (Linux/macOS only). `prune_bundle()` removes the libraries JuliaC bundles for
  stdlibs that are only in the compiling Julia's system image (e.g. OpenBLAS),
  not in the image's environment (Julia >= 1.14).
- **R side (`R/`)** — `library.R`: `install_library()` / `build_library()`
  (finds clients, runs `build.jl`, stores the library under
  `R_user_dir("jlbind", "cache")/library/` with the client versions and binding
  package hashes (`.binding_hash()`) it was built from, so it is rebuilt when a
  client's Julia code changes without a version bump).
  `install_library(private = )` also builds a privatized library per listed
  client under `R_user_dir("jlbind", "cache")/private/<pkg>/`, and records the
  private clients in `R_user_dir("jlbind", "config")/private-packages`, which
  keeps them private on later builds and survives a cleared cache. `clients.R`:
  client discovery via the `Config/jlbind` DESCRIPTION field. `runtime.R`:
  `bind_client(pkg)` called from a client's `.onLoad`, loads the library once,
  sets threads, binds a client only if the library was built from its installed
  version. Each library has a state environment: `.state` itself for the shared
  one, `.state$private[[path]]` for privatized ones (`Private` salt in the
  `build` file); `.library_path()` picks a client's library. `sitrep.R`:
  `jlbind_sitrep()`, a report on Julia, the library and each client that works
  before a library has loaded. `scaffold.R`: `use_jlbind()` and
  `update_entrypoints()`, which scans `@rcall` declarations (with
  comments/strings blanked, so they must be literal top-level `@rcall`s) and
  writes `R/jlbind-wrappers.R`. `julia.R`: locating Julia.

Clients are pure R packages, so a fix to how they call the library needs only a
jlbind update. `R/jlbind-wrappers.R` defines `.jlbind_module`, `.jlbind_entries`
(the entrypoint names) and an environment `.jlbind`; each wrapper is
`.External(.jlbind$.call, .jlbind$<name>, args...)`. `bind_client()`
(`.set_entries()`) fills `.jlbind` with external pointers to
`jlbind<n>_<Module>_<name>` (`.entry_symbols()`) from `jlbind_entries()` in
`src/call.c` (null ones while unbound, which give the "not available" error),
which looks the symbols up with `dlsym`/`GetProcAddress` on the handle of the
library's `DLLInfo` (`.dll_entries()`), since every library has the DLL name
`jlbind`, and `.call` with the address of `jlbind_call()`, which passes the
arguments as an array and raises a `jlbind_error` as an R error. `.call` is
stored as the bare address, not a `NativeSymbolInfo`, because R CMD check flags
a client's calls to another package's `NativeSymbolInfo`.

jlbind's own `src/state.c` has the ALTREP class that lets a reference be saved
(see `r_saved_by` in `refs.jl`): R must find the class when loading a file,
before or without the library. JLBind finds its `jlbind_state_hook` with
`R_GetCCallable()` when first needed, since binding must not start Julia. A
reference's external pointer has the tag `jlbind_ref` and, as its protected
value, a symbol naming the runtime that made it (`_runtime()`), so a live
reference from another (private) runtime is rejected.

The test clients in `tests/clients/{hellojl,counterjl}` are scaffolded output:
their `R/zzz.R` and `R/jlbind-wrappers.R` correspond to `inst/templates/` and
`update_entrypoints()`. When changing a template or the header generator, update
the test clients to match.

## Constraints to keep in mind

- Everything in the library is compiled with `--trim=safe`, so every Julia call
  must be statically resolvable. A function receiving an abstract `RRef{T}` must
  take it as `@nospecialize(x::T)` and branch on concrete types (`@narrow`);
  `Core.invoke` is not accepted by trim verification (Julia 1.13). A call with
  more than two union-typed arguments is not union-split, so `@rcall` calls `f`
  in a branch per `nothing`/`missing` of each argument declared as a literal
  `Union{Nothing,T}`/`Union{Missing,T}` (`_union_with` in `rcall.jl`).
- `@R(sym)` must name `R.dll` on Windows; Windows builds record `julia_bindir`
  so R can find the Julia runtime before loading the DLL.
- Never write into an installed package directory; builds work on scratch
  copies.
- `experiments/two-libs/` (excluded from the build) demonstrates why two juliac
  libraries cannot coexist in one process.
