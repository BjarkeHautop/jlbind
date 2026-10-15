# The binding package of the counterjl test client: Julia objects held by R.
module CounterBindings

using JLBind

mutable struct Counter
    n::Int64
end

JLBind.r_class(::Type{Counter}) = "counter"

new_counter(start::Int64) = Counter(start)
increment(c::Counter, by::Int64) = (c.n += by; c.n)
counters(n::Int64) = [Counter(i) for i = 1:n]
live() = JLBind.object_count()

@rcall new_counter(start::Int64 = 0)::RRef{Counter}
@rcall increment(counter::RRef{Counter}, by::Int64 = 1)::Int64
@rcall counters(n::Int64)::Vector{RRef{Counter}}
@rcall live()::Int64

end
