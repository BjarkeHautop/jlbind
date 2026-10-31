# Numeric kernels for the cpu_target benchmark (bench-numeric.R): append to
# tests/clients/hellojl/inst/julia/src/HelloBindings.jl, before its final
# `end`, in a copy of hellojl.

function matmul(n::Int64)
    a = [sin(i + j) for i in 1:n, j in 1:n]
    b = [cos(i - j) for i in 1:n, j in 1:n]
    c = zeros(n, n)
    @inbounds for j in 1:n, k in 1:n
        bkj = b[k, j]
        @simd for i in 1:n
            c[i, j] += a[i, k] * bkj
        end
    end
    return sum(c)
end
function dotsum(x::Vector{Float64}, reps::Int64)
    s = 0.0
    for _ in 1:reps
        acc = 0.0
        @inbounds @simd for i in eachindex(x)
            acc += x[i] * x[i]
        end
        s += acc
    end
    return s
end
mapexp(x::Vector{Float64}) = sum(v -> exp(v) * sin(v), x)
sortsum(x::Vector{Float64}) = sort(x)[div(length(x), 2)]
function lorenz(steps::Int64)
    u = (1.0, 0.0, 0.0); h = 1e-3
    f(u) = (10.0 * (u[2] - u[1]), u[1] * (28.0 - u[3]) - u[2], u[1] * u[2] - 8 / 3 * u[3])
    for _ in 1:steps
        k1 = f(u); k2 = f(u .+ h / 2 .* k1); k3 = f(u .+ h / 2 .* k2); k4 = f(u .+ h .* k3)
        u = u .+ h / 6 .* (k1 .+ 2 .* k2 .+ 2 .* k3 .+ k4)
    end
    return u[1] + u[2] + u[3]
end
@rcall matmul(n::Int64)::Float64
@rcall dotsum(x::Vector{Float64}, reps::Int64)::Float64
@rcall mapexp(x::Vector{Float64})::Float64
@rcall sortsum(x::Vector{Float64})::Float64
@rcall lorenz(steps::Int64)::Float64
