# The binding package of the benchjl client, with the functions
# vignettes/articles/performance.qmd benchmarks.
module benchjlBindings

using JLBind

greet(name::String) = "Hello, " * name * "!"
shift(x::Vector{Float64}, by::Float64) = x .+ by

@rcall greet(name::String)::String
@rcall shift(x::Vector{Float64}, by::Float64)::Vector{Float64}

end
