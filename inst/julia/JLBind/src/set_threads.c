/*
 * Set the Julia thread count before the runtime initializes.
 *
 * A juliac library fixes its options when it is compiled (one thread, Julia
 * signal handling off) and ignores JULIA_NUM_THREADS, so the jlbind R package
 * calls this (with .C) right after loading the library and before the first
 * entrypoint, which is what initializes Julia.
 * Adapted from Ribasim's set_julia_threads.c; see
 * https://github.com/JuliaLang/JuliaC.jl/issues/152.
 *
 * `status` is set to 0 on success, 1 if Julia is already initialized, and 2
 * if the thread count is invalid.
 */

#include <julia.h>
#include <stdint.h>

#ifdef _WIN32
#define JLBIND_EXPORT __declspec(dllexport)
#else
#define JLBIND_EXPORT __attribute__((visibility("default")))
#endif

static int16_t threads_per_pool[1];

JLBIND_EXPORT void jlbind_set_julia_threads(int *threads, int *status)
{
    /* Julia reads jl_options once, while initializing the runtime. */
    if (jl_is_initialized()) {
        *status = 1;
        return;
    }
    if (*threads < 1 || *threads > INT16_MAX) {
        *status = 2;
        return;
    }

    /* JuliaC already parsed --threads=1, so update every field
     * jl_init_threading reads. */
    threads_per_pool[0] = (int16_t)*threads;
    jl_options.nthreadpools = 1;
    jl_options.nthreads = (int16_t)*threads;
    jl_options.nthreads_per_pool = threads_per_pool;

    /* Julia's GC needs signal-based safepoints when several threads run. */
    jl_options.handle_signals = *threads > 1 ? JL_OPTIONS_HANDLE_SIGNALS_ON
                                             : JL_OPTIONS_HANDLE_SIGNALS_OFF;
    *status = 0;
}
