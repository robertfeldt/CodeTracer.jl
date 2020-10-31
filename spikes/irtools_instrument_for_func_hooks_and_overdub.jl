# Small example showing how to instrument Julia code at IR level
# in order to prehook/posthook function calls. Then also shows
# how to overdub calls so that we can, for example, do mutation testing.

# We want to call prehook and posthook methods on a tracer for every function call
# in a function in focus (FIF)
function fif(x, y)
    # Just insert a delay so we can measure overhead more realistically below...
    sleep(0.0001)
    if x < y
        return x + y
    else
        return x - y
    end
end

# We will add a code tracer argument which is then invoked on different events
# while executing the function. By default nothing happens on these events
# but subtypes can override.
abstract type CodeTracer end
@inline enterfunction!(c::CodeTracer, func, numblocks::Int) = nothing
@inline enterblock!(c::CodeTracer, block::Int) = nothing
@inline prehook(c::CodeTracer, id::Int, func, args...) = nothing
@inline overdub(c::CodeTracer, id::Int, func, args...) = func(args...)
@inline posthook(c::CodeTracer, id::Int, res, func, args...) = nothing

# Let's trace function calls by adding posthooks as well as tracing
# function entry.
mutable struct FunctionCallTracer <: CodeTracer
    trace::Vector{Any}
end
FunctionCallTracer() = FunctionCallTracer(Any[])

@inline enterfunction!(c::FunctionCallTracer, funcname, numblocks::Int) =
    push!(c.trace, [:entry, funcname, numblocks])

@inline posthook(c::FunctionCallTracer, id::Int, res, func, args...) =
    push!(c.trace, [:posthook, id, res, func, args...])

# Now use IRTools so we can instrument functions to insert callbacks 
# to a tracer object that we will take in as a new first argument.
using IRTools
using IRTools: @code_ir, blocks, argument!, func, xcall

numblocks(ir) = length(blocks(ir))

function instrument!(ir, fn = nothing)
    tracerarg = argument!(ir; at = 2) # add tracer argument to function

    # Walk over all statements and pre/posthook function calls:
    num = 1 # we increment this number for every call so that each call has a unique id num
    for (v, s) in ir
        if s.expr.head == :call
            # prehook:
            insert!(ir, v, xcall(Main, :prehook, tracerarg, num, s.expr.args...))
            # posthook:
            IRTools.insertafter!(ir, v, xcall(Main, :posthook, tracerarg, num, v, s.expr.args...))
            # overdub: 
            ir[v] = xcall(Main, :overdub, tracerarg, num, s.expr.args...)
            num += 1
        end
    end

    # Add enterblock! calls at the start of each block:
    bs = blocks(ir)
    for bi in eachindex(bs)
        pushfirst!(bs[bi], xcall(Main, :enterblock!, tracerarg, bi))
    end

    # This should come after the loop above so it is really added first in the whole
    # function:
    pushfirst!(ir, xcall(Main, :enterfunction!, tracerarg, fn, numblocks(ir)))

    ir
end

# Get the IR, instrument it, and turn into a new lambda/function:
ir = old_ir = @code_ir fif(2, 3)
instrumented_ir = instrument!(old_ir, fif)
f2 = func(instrumented_ir); # Make a new function from the instrumented ir

# Ok, let's test this!

origres = fif(2, 3)
tr = FunctionCallTracer()
res = f2(nothing, tr, 2, 3)
@assert origres == res
@assert length(tr.trace) == 4 # funcentry, posthook sleep, posthook <, posthook +
@assert tr.trace[1][1] == :entry
@assert tr.trace[2][4] == Main.sleep
@assert tr.trace[3][4] == Main.:<
@assert tr.trace[4][4] == Main.:+
@assert tr.trace[4][3] == 5

# We can also do mutation testing via overdub. Let's even do a dynamic
# mutation tracer which we can control flexibly from the outside.
mutable struct DynamicFuncMutator <: CodeTracer
    mutatedfuncs::Dict{Tuple{Int, Any}, Any}
end
DynamicFuncMutator() = DynamicFuncMutator(Dict{Tuple{Int, Any}, Any}())
shouldmutate(c::DynamicFuncMutator, id::Int, func) = haskey(c.mutatedfuncs, (id, func))
resetfunc!(c::DynamicFuncMutator, id::Int, func) = delete!(c.mutatedfuncs, (id, func))
setfunc!(c::DynamicFuncMutator, id::Int, func, altfunc) = c.mutatedfuncs[(id, func)] = altfunc
@inline function overdub(c::DynamicFuncMutator, id::Int, func, args...)
    func2call = shouldmutate(c, id, func) ? c.mutatedfuncs[(id, func)] : func
    func2call(args...)
end

# Now we can dynamically mutate the first comparison operator (originally <) to
# > like so:
m = DynamicFuncMutator()
r1 = fif(2, 3)    # Returns 5
r2 = f2(nothing, m, 2, 3) # also returns 5 since no mutation yet...
@assert r2 == r1
setfunc!(m, 2, Main.:<, Main.:>) # id num is 2 since call to sleep is 1
r3 = f2(nothing, m, 2, 3) # returns -1 since 2-3==-1
@assert r3 == -1
# Now delete the mutation and add another one:
resetfunc!(m, 2, Main.:<)
setfunc!(m, 3, Main.:+, Main.:*)
r4 = f2(nothing, m, 2, 3) # returns 6 since 2*3==6
@assert r4 == 6