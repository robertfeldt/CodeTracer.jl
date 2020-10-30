# Small example showing how to instrument Julia code at IR level
# in order to prehook/posthook function calls.

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

# We will use a coverage object to count the number of executions of each basic block.
abstract type CodeTracer end

mutable struct FunctionCallTracer <: CodeTracer
    trace::Vector{Any}
end
FunctionCallTracer() = FunctionCallTracer(Any[])

enterfunction!(c::FunctionCallTracer, funcname, numblocks::Int) =
    push!(c.trace, [:funcentry, funcname, numblocks])

enterblock!(c::FunctionCallTracer, block::Int) = nothing

prehook(c::FunctionCallTracer, id::Int, func, args...) = nothing

posthook(c::FunctionCallTracer, id::Int, res, func, args...) =
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
            #fn = first(s.expr.args)
            insert!(ir, v, xcall(Main, :prehook, tracerarg, num, s.expr.args...)) # fn, s.expr.args[2:end]...))
            IRTools.insertafter!(ir, v, xcall(Main, :posthook, tracerarg, num, v, s.expr.args...)) # fn, s.expr.args[2:end]...))
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
@assert tr.trace[1][1] == :funcentry
@assert tr.trace[2][4] == Main.sleep
@assert tr.trace[3][4] == Main.:<
@assert tr.trace[4][4] == Main.:+
@assert tr.trace[4][3] == 5