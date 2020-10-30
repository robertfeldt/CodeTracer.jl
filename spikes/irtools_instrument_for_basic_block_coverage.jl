# Small example showing how to instrument Julia code at IR level
# in order to collect basic block coverage information during execution.

# We want to measure basic block coverage when testing this method:
function f(x, y)
    # Just insert a delay so we can measure overhead more realistically below...
    sleep(0.001)
    if x < y
        return x + y
    else
        return x - y
    end
end

# We will use a coverage object to count the number of executions of each basic block.
mutable struct BasicBlockCoverage
    blockexecutions::Vector{Int}
end

BasicBlockCoverage(n::Int) = BasicBlockCoverage(zeros(Int, n))

function enterfunction!(c::BasicBlockCoverage, numblocks::Int)
    @assert numblocks == length(c.blockexecutions)
end

enterblock!(c::BasicBlockCoverage, block::Int) = 
    c.blockexecutions[block] += 1

function coverage(c::BasicBlockCoverage)
    length(c.blockexecutions) == 0 && return 0.0
    sum(c.blockexecutions .> 0) / length(c.blockexecutions)
end

# Now use IRTools so we can instrument functions to insert callbacks 
# to a tracer object that we will take in as a new first argument.
using IRTools: @code_ir, blocks, argument!, func, xcall

numblocks(ir) = length(blocks(ir))

function instrument!(funcname::Symbol, ir)
    bs = blocks(ir)
    tracerarg = argument!(ir; at = 2) # add tracer argument to function
    for bi in eachindex(bs)
        pushfirst!(bs[bi], xcall(Main, :enterblock!, tracerarg, bi))
    end
    # This should come after the loop above so it is really added first in the whole
    # function:
    pushfirst!(ir, xcall(Main, :enterfunction!, tracerarg, numblocks(ir)))
    ir
end

# Get the IR, instrument it, and turn into a new lambda/function:
old_ir = @code_ir f(2, 3)
instrumented_ir = instrument!(:f, old_ir)
f2 = func(instrumented_ir); # Make a new function from the instrumented ir

# Ok, let's test this!

# Ensure same output:
origres = f(2, 3)
c0 = BasicBlockCoverage(numblocks(old_ir))
res = f2(nothing, c0, 2, 3)
@assert origres == res

# If we only run it once we should cover only 2 of 3 basic blocks:
c = BasicBlockCoverage(numblocks(old_ir))
f2(nothing, c, 2, 3)
@assert round(coverage(c), digits = 2) == 0.67

# But if we run 99 more times with random inputs we are very likely 
# to get 100% coverage:
for _ in 1:99
    x = rand(0:10)
    y = rand(0:10)
    f2(nothing, c, x, y)
end
@assert coverage(c) == 1.0

# Overhead is not too bad:
using BenchmarkTools
torig = @belapsed f(2, 3)
t     = @belapsed f2(nothing, c, 2, 3)
overhead = round(100.0 * (t/torig - 1.0), digits = 2) # About 17% on my machine...