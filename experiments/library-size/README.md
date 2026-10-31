# How big is the library, and what does the CPU target cost?

Sizes of the library `install_library()` builds, with the options that change
them, and run times for each CPU target. These measurements led to jlbind
building with `-g0` and `cpu_target = "native"` by default.

## Setup (2026-10-31)

Linux x86-64, AMD Ryzen 7 8845HS (Zen 4, AVX-512), JuliaC 0.3.12. Julia 1.13.2
and 1.14.0-alpha2. The libraries were built with `build_library()`. The client
is CausalStructures (graph algorithms) unless noted, and the numeric client is
`hellojl` with `kernels.jl` added.

## Library size (CausalStructures, MB)

  | Variant                                      | As built | After `strip` | Code (`.text`) | Debug info |
  | -------------------------------------------- | -------: | ------------: | -------------: | ---------: |
  | 1.13, JuliaC defaults                        |     52.0 |          19.7 |           13.9 |       30.9 |
  | 1.14, JuliaC defaults                        |     25.9 |          19.8 |           14.3 |        4.8 |
  | 1.14 + `-g0`                                 |     21.1 |          19.8 |           14.3 |          0 |
  | 1.14 + `cpu_target = "generic"`              |     10.2 |           8.3 |            3.9 |        1.4 |
  | 1.14 + `"generic"` + `-g0`                   |      8.8 |           8.3 |            3.9 |          0 |
  | 1.14 + `"generic,min_size"` + `-g0`          |      8.4 |           8.0 |            3.6 |          0 |
  | 1.14 + `"native"` + `-g0` (jlbind's default) |      8.9 |               |                |          0 |
  | 1.14 + `"generic;native,clone_all"` + `-g0`  |     13.7 |               |                |          0 |

- JuliaC's default CPU target is that of Julia's system image,
  `generic;sandybridge,-xsaveopt,clone_all;haswell,-rdrnd,base(1);x86-64-v4,-rdrnd,base(1)`,
  which compiles the code about 3.7 times. A single target (`generic` or
  `native`) is what shrinks it.
- Most of the rest is debug info. Julia 1.14 writes far less of it than 1.13.
  jlbind returns errors as messages without backtraces, so nothing uses it, and
  `-g0` removes it.
- Build times: 67 s with the default target, 49 s with `generic`, 34 s with
  `native`.

## Run time by CPU target (relative to JuliaC's default; lower is faster)

  | Client           | Task                         | `generic` | `native` | `generic;native,clone_all` |
  | ---------------- | ---------------------------- | --------: | -------: | -------------------------: |
  | CausalStructures | `uniform_dag(150)`           |      0.95 |     0.95 |                       0.92 |
  | CausalStructures | `dag_to_cpdag`, 150 nodes    |      1.00 |     1.00 |                       1.00 |
  | CausalStructures | `count_dags` ×200            |      1.01 |     1.00 |                       0.99 |
  | CausalStructures | `mag_to_pag` ×100            |      0.98 |     0.98 |                       0.98 |
  | numeric          | matmul 1000×1000 (SIMD loop) |      1.68 |     1.01 |                       1.01 |
  | numeric          | dot product (SIMD loop)      |      2.61 |     0.93 |                       0.93 |
  | numeric          | `exp`/`sin` over 2e7 values  |      1.14 |    ~1.07 |                       2.22 |
  | numeric          | sort 2e7 values              |      1.05 |     ~1.0 |                       ~1.0 |
  | numeric          | RK4 Lorenz (scalar)          |      1.01 |     ~1.0 |                       1.01 |

- Graph code doesn't care. `generic` makes SIMD loops 1.7–2.6× slower, because
  it gives up AVX.
- `native` is as fast as the default at less than half the size, but it may
  crash on another CPU, so jlbind records the CPU model and won't load the
  library on another (`.cpu_mismatch()`).
- `generic;native,clone_all` (fast here, with a fallback elsewhere) is worse:
  calls into multiversioned functions (`exp`, `sin`) are about 2× slower,
  consistently over reruns.

To reproduce, build each variant with
`build_library(..., cpu_target = , julia_args = )`, then run
`bench-causalstructures.R` and `bench-numeric.R`.

## The Julia runtime the library loads (MB)

The library needs `libjulia`, `libjulia-internal`, `libunwind`, `libz`,
`libzstd` and `libatomic`. Julia's loader also `dlopen`s `libgcc_s` and
`libopenlibm` as it starts. It needs no LLVM, codegen or OpenBLAS.

  | Julia         | `libjulia-internal` | All of these |
  | ------------- | ------------------: | -----------: |
  | 1.13.2        |                  15 |           17 |
  | 1.14.0-alpha2 |                 4.5 |          6.1 |

## Standalone bundles (no Julia installed)

A library can be made standalone with JuliaC's `BundleRecipe` (`--bundle`). The
CausalStructures library on 1.14 (`generic`, `-g0`):

- The raw bundle is 83 MB. It copies Julia's whole runtime library set, such as
  OpenBLAS (36 MB), libstdc++, libcrypto, curl and libgit2, none of which is
  used.
- Keeping only the libraries above, and stripping `jlbind.so`, leaves 15.5 MB
  (about 5 MB with xz), and it runs with no Julia installed. `hellojl` comes to
  9.1 MB and `counterjl` to 8.5 MB.
- The bundle needs `rpath = "@bundle"` in the `LinkRecipe`. Otherwise the
  library still points at the Julia install.
- Stripping the privatized `libjulia` or `libjulia-internal` makes R segfault
  when it loads them, because LIEF has rewritten them. Stripping `jlbind.so` is
  fine.

Two separate libraries can share one R process if each bundles its own
`--privatize`d runtime (see `../two-libs/`, where unprivatized ones abort).
`hellojl` and `counterjl` worked side by side with 4 threads each, through
interleaved calls, GCs and RRef finalizers, in either load order. Each needs its
own salt, though: JuliaC derives the default salt from the output name, the
project and the Julia version, which are the same in every jlbind build. Linux
only: JuliaC doesn't privatize on Windows.
