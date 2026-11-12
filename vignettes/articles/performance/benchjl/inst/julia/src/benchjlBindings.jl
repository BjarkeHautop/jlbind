# The binding package of the benchjl client, with the functions
# vignettes/articles/performance.qmd benchmarks.
module benchjlBindings

using JLBind

greet(name) = "Hello, " * name * "!"
shift(x, by) = x .+ by

@rcall greet(name::String)::String
@rcall shift(x::Vector{Float64}, by::Float64)::Vector{Float64}

end # module benchjlBindings
