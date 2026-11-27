# The binding package of the hellojl test client: a hello world, kept small
# for the tests that build a library of one client.
module HelloBindings

using JLBind

greet(name) = "Hello, " * name * "!"
shift(x, by) = by === nothing ? x : x .+ by
fail(msg) = throw(ArgumentError(msg))
threads() = Int64(Threads.nthreads())
# Julia opens PCRE2 (for a Regex) and GMP (for a BigInt) by file name when
# first used, which on Windows needs the Julia runtime on the PATH.
count_matches(pattern, s) = Int64(count(Regex(pattern), s))
big_digits(n) = Int64(ndigits(factorial(big(n))))

@rcall greet(name::String)::String
@rcall shift(x::Vector{Float64}, by::Union{Nothing,Float64} = nothing)::Vector{Float64}
@rcall fail(msg::String)::Nothing
@rcall threads()::Int64
@rcall count_matches(pattern::String, s::String)::Int64
@rcall big_digits(n::Int64)::Int64

end # module HelloBindings
