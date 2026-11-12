# The binding package of the counterjl test client: Julia objects held by R.
module CounterBindings

using JLBind

mutable struct Counter
    n::Int64
end

JLBind.r_class(::Type{Counter}) = "counter"

new_counter(start) = Counter(start)
increment(c, by) = (c.n += by; c.n)
counters(n) = [Counter(i) for i = 1:n]
total(cs) = sum(c.n for c in cs; init = 0)
live() = JLBind.object_count()

# An object that survives saveRDS(); a `Counter` does not.
struct Point
    x::Float64
end

JLBind.r_class(::Type{Point}) = "point"
JLBind.r_saved_by(::Type{Point}) = "counterjl"
JLBind.r_restore(::Type{Point}, state::SEXP) = Point(from_sexp(Float64, JLBind.vector_elt(state, 0)))

new_point(x) = Point(x)
points(n) = [Point(i) for i = 1:n]
point_x(p) = p.x

@rcall new_point(x::Float64)::RRef{Point}
@rcall points(n::Int64)::Vector{RRef{Point}}
@rcall point_x(point::RRef{Point})::Float64

@rcall new_counter(start::Int64 = 0)::RRef{Counter}
@rcall increment(counter::RRef{Counter}, by::Int64 = 1)::Int64
@rcall counters(n::Int64)::Vector{RRef{Counter}}
@rcall total(counters::Vector{RRef{Counter}})::Int64
@rcall live()::Int64

end # module CounterBindings
