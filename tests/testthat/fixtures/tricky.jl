# @rcall commented(x::Int64)::Int64
#= @rcall block(x::Int64)::Int64
   #= nested =# @rcall stillblock(x::Int64)::Int64 =#
"""
    @rcall docstring(x::Int64)::Int64
"""
s = "@rcall instring(x)::Int64 \" @rcall escaped(x)::Int64"
c = '"'
d = '\''
t = x' * "@rcall afteradjoint(x)::Int64"
@rcall real(x::Int64, y::Int64)::Int64  # trailing (comment, here)
