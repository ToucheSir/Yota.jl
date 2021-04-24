########################################################################
#                            GRAD CONTEXT                              #
########################################################################

# TODO: use it in tape instead of hardcoded fields
# the issue is with rebind_fields!() which must know context details
# perhaps introduce rebind_context!() wich is no-op by default?
struct GradContext
    # map from primal var to its pullback var
    # note: LittleDict is required because vars are mutable
    pullbacks::LittleDict{Variable, Variable}
    # map from primal var to its derivative var
    derivs::LittleDict{Variable, Variable}
end


########################################################################
#                              GRAD                                    #
########################################################################

const DEBUG_STATE = Ref{Any}()


getderiv(tape::Tape, id::Int) = haskey(tape.derivs, id) ? tape[tape.derivs[id]] : nothing
getderiv(tape::Tape, op::AbstractOp) = getderiv(tape, op.id)
setderiv!(tape::Tape, op_id::Int, grad_op_id::Int) = (tape.derivs[op_id] = grad_op_id)
setderiv!(tape::Tape, op::AbstractOp, grad_op::AbstractOp) = (tape.derivs[op.id] = grad_op.id)


function set_or_add_deriv!(tape::Tape, x::AbstractOp, dx::AbstractOp)
    if !haskey(tape.derivs, x.id)
        setderiv!(tape, x, dx)
    else
        old_dx = getderiv(tape, x)
        if dx.val isa Composite || old_dx.val isa Composite
            val = dx.val + old_dx.val
            new_dx_id = record!(tape, Call, val, (+), [dx.id, old_dx.id])
        else
            val = dx.val .+ old_dx.val
            dot_add_id = record!(tape, Constant, +)
            new_dx_id = record!(tape, Call, val, broadcast, [dot_add_id, dx.id, old_dx.id])
        end
        new_dx = tape[new_dx_id]
        setderiv!(tape, x, new_dx)
    end
end


# function step_back!(tape::Tape, op::Union{Call}, i::Int)
#     y = op
#     dy = getderiv(tape, y)
#     dy !== nothing || return           # op is not part of computation graph
#     op.args[i] isa Variable || return  # constant arg
#     x = tape[op.args[i].id]
#     if dy.val isa Zero
#         # propagate zero to dx (reuse dy node)
#         set_or_add_deriv!(tape, x, dy)
#         return
#     end
#     # TODO: finish
# end

function step_back!(tape::Tape, y::Variable)
    # 1. [step_back] get pullback (or fail) for y, push! to tape, destruct the tuple, set_or_add_deriv
    @assert haskey(tape.pullbacks, y) "No pullback for op $(tape[y])"
    pb = tape.pullbacks[y]
    dxs = push!(tape, mkcall(pb, y))
    y_fargs = (tape[y].fn, tape[y].args...)
    for (i, x) in enumerate(y_fargs)
        if x isa V
            dx = push!(tape, mkcall(getfield, dxs, i))
            # TODO: set_or_add_deriv!
        end
    end
end


"""
Backpropagate through the tape, record derivatives as new operations
"""
function back!(tape::Tape)
    # z - final variable (usually a loss)
    # y - resulting variable of current op
    # x - dependencies of y
    # dy - derivative of z w.r.t. y
    z = tape.result
    # using one() of type of the result for seed to keep type stability
    @assert ndims(tape[z].val) == 0 "Function must return scalar!"
    dy = push!(tape, Constant(one(tape[z].val)))
    # set initial derivative value
    tape.derivs[z] = dy
    # queue of variables to calculate derivatives for
    deriv_todo = V[z]
    while !isempty(deriv_todo)
        y = popfirst!(deriv_todo)
        step_back!(tape, y)
        # add y's dependencies to deriv_todo
        for x in (tape[y].fn, tape[y].args...)
            if x isa V
                push!(deriv_todo, x)
            end
        end
    end
    # for op in reverse(tape.ops[1:end-1])
        # if op isa Call
        #     # ordinary function call
        #     for i=1:length(op.args)
        #         @show op, i
        #         # backpropagate only non-constant vars
        #         # note that it also prevents backprop on 1st param of broadcast
        #         arg_var = op.args[i]
        #         if (arg_var isa Variable &&
        #             !isa(tape[arg_var.id], Constant) &&
        #             !dont_diff(tape, op, i))
        #             step_back!(tape, op, i)
        #         end
        #     end
        # end
    # end
end


"""
For each input that has a derivative on this tape check if the derivative
has the same size as the input.
"""
function check_deriv_sizes(tape::Tape)
    for (var_id, grad_var_id) in tape.derivs   # TODO: apply to pb_derivs as well
        # type of var and grad var may differ e.g. when grad_var is Zero()
        # if !isstruct(tape[var_id].val) && !isstruct(tape[grad_var_id].val)
        if tape[var_id].val isa AbstractArray && tape[grad_var_id].val isa AbstractArray
            var_size = size(tape[var_id].val)
            grad_var_size = size(tape[grad_var_id].val)
            if  var_size != grad_var_size
                @warn "Gradient %$grad_var_id has size $grad_var_size, " *
                    "but original variable %$var_id has size $var_size"
            end
        end
    end
end


function chainrules_transform!(tape::Tape)
    i = 1
    while i <= length(tape)
        op = tape[V(i)]
        if op isa Call && is_chainrules_primitive(call_signature(tape, op))  # TODO: and not normal deriv
            rr_op = mkcall(rrule, op.fn, op.args...)
            val_op = mkcall(getindex, V(rr_op), 1)
            pb_op = mkcall(getindex, V(rr_op), 2)
            tape.pullbacks[V(val_op)] = V(pb_op)
            replace!(tape, i => [rr_op, val_op, pb_op]; rebind_to=2)
            i += 3
        else
            i += 1
        end
    end
    return tape
end


"""
Calculate and record to the tape gradients of `tape[tape.resultid]` w.r.t. `Input` nodes
"""
function _grad(tape::Tape)
    # apply preprocessing transformations
    # tape = preprocess(tape)
    # apply transformations needed for ChainRules
    chainrules_transform!(tape)
    # backpropagate gradients
    back!(tape)
    # consistency check
    check_deriv_sizes(tape)
    # apply postprocessing transformations
    # tape = postprocess(tape)
    return tape
end


function _grad(f::Function, args...)
    val, tape = trace(f, args...)
    # calculate gradients
    tape = _grad(tape)
    # construct GradResult object that wraps tape and provides accessors for computed derivatives
    return val, GradResult(tape)
end


const DYNAMIC_GRAD_CACHE = Dict{Any, Tape}()

function _dynamic_grad(f::Function, args...)
    val, tape = trace(f, args...)
    if haskey(DYNAMIC_GRAD_CACHE, tape)
        # take already processed tape from the cache and just play it
        key = tape
        tape = DYNAMIC_GRAD_CACHE[key]
        # play to propagate both - value (should be unchanged) and gradients
        val = play!(tape)
        return val, GradResult(tape)
    else
        # copy tape just after tracing to use as key in cache later
        key = deepcopy(tape)
        # calculate gradients
        tape = _grad(tape)
        # save to cache
        DYNAMIC_GRAD_CACHE[key] = tape
        return val, GradResult(tape)
    end
end


const GRAD_CACHE = Dict{Any, Tape}()


"""
Find gradient of `f` w.r.t. its arguments.
Example:

    val, g = grad(sum, rand(3))

where:
  - val is the value of `f` at this point
  - g::GradResult is a collection of gradients

GradResult is indexed by argument index and contains gradients
in a format most suitable for that argument, namely:

  - for arrays: arrays of the same type and size
  - for reals: reals
  - for mutable structs: dictionary of {(:field, :path) => value} pairs.

All gradients can be applied to original variables using `update!()` function.
"""
function grad(f::Function, args...; dynamic=false)
    # key consists of function type and type of argument (for structs) or its size
    cache_key = (f, ([isstruct(arg) ? typeof(arg) : size(arg) for arg in args]...,))
    if dynamic
        return _dynamic_grad(f, args...)
    elseif haskey(GRAD_CACHE, cache_key)
        tape = GRAD_CACHE[cache_key]
        val = play!(tape, args...)
        return val, GradResult(tape)
    else
        val, g = _grad(f, args...)
        compile!(g.tape)
        GRAD_CACHE[cache_key] = g.tape
        return val, g
    end
end


function simplegrad(f, args...)
    val, g = _grad(f, args...)
    return compile(g.tape, bind=false, ret_grad=true)
end
