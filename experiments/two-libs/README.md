# Can two juliac libraries share one R process?

Two tiny packages, `liba` and `libb`, each compiled with
`juliac --output-lib --trim=safe` (`build.jl`), loaded into one R session with
`dyn.load()` and called through `.Call`. Run `./run.sh` to reproduce.

## Result (Julia 1.13.1, JuliaC 0.3, Linux x86-64, 2026-10-12)

Separate libraries don't work: whichever library is called first works, and the
first call into the other aborts the process:

```
#4  abort ()
#5  jl_init_threadtls (tid=-1)        src/threading.c:328
#6  ijl_adopt_thread ()               src/threading.c:441
#7  libb_r_greet ()                   libb.so
```

One combined library works: `combined` is a package whose module only does
`using liba, libb`. juliac exports the `@ccallable`s of dependency packages too
(`nm -D out/combined.so` lists `liba_r_*` and `libb_r_*`), and calling both
packages alternately, with Julia and R GCs forced in between, works and keeps
each package's state separate.
