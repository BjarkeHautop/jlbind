# The binding package of the hellojl test client: plain values both ways.
module HelloBindings

using JLBind

greet(name::String) = "Hello, " * name * "!"
shift(x::Vector{Float64}, by::Union{Nothing,Float64}) = by === nothing ? x : x .+ by
describe(x::Vector{Float64}) =
    (n = length(x), mean = sum(x) / length(x), range = [minimum(x), maximum(x)])
fail(msg::String) = throw(ArgumentError(msg))
threads() = Int64(Threads.nthreads())
upper(xs::Vector{Symbol}) = [Symbol(uppercase(String(x))) for x in xs]
evens(n::Int64) = Int32[i for i = 2:2:n]

@rcall greet(name::String)::String
@rcall shift(x::Vector{Float64}, by::Union{Nothing,Float64})::Vector{Float64}
@rcall describe(x::Vector{Float64})::NamedTuple{(:n, :mean, :range),Tuple{Int64,Float64,Vector{Float64}}}
@rcall fail(msg::String)::Nothing
@rcall threads()::Int64
@rcall upper(xs::Vector{Symbol})::Vector{Symbol}
@rcall evens(n::Int64)::Vector{Int32}

end
