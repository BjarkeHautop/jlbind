module libb
include("../../rmini.jl")
const SEEN = Dict{String,Int}()
Base.@ccallable function libb_r_greet(x::SEXP)::SEXP
    s = _utf8(x)
    SEEN[s] = get(SEEN, s, 0) + 1
    junk = [string(i) for i in 1:10_000]
    return _string("hello " * s * " #" * string(SEEN[s]) * " " * junk[end])
end
Base.@ccallable function libb_r_gc()::SEXP
    GC.gc()
    return _scalar_real(Float64(length(SEEN)))
end
end
