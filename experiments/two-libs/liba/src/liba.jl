module liba
include("../../rmini.jl")
const STATE = Ref{Float64}(0.0)
# Sum of x, via a fresh Julia allocation (exercises Julia's GC).
Base.@ccallable function liba_r_sum(x::SEXP)::SEXP
    v = copy(unsafe_wrap(Array, _real_ptr(x), _length(x)))
    junk = [rand(100) for _ in 1:1000]
    STATE[] += sum(v)
    return _scalar_real(sum(v) + 0 * sum(sum, junk))
end
Base.@ccallable function liba_r_state()::SEXP
    return _scalar_real(STATE[])
end
Base.@ccallable function liba_r_gc()::SEXP
    GC.gc()
    return _scalar_real(Float64(Threads.nthreads()))
end
end
