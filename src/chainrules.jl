import ChainRulesCore: rrule, no_rrule
import ChainRulesCore: rrule_via_ad, RuleConfig, NoForwardsMode, HasReverseMode
import Umlaut: make_name, Input, to_expr


###############################################################################
#                              RuleConfig                                     #
###############################################################################

"""
    YotaRuleConfig()

ChainRules.RuleConfig passed to all `rrule`s in Yota.
Extends RuleConfig{Union{NoForwardsMode,HasReverseMode}}.
"""
struct YotaRuleConfig <: RuleConfig{Union{NoForwardsMode,HasReverseMode}} end


###############################################################################
#                              rrule_via_ad                                   #
###############################################################################


function to_rrule_expr(tape::Tape)
    # TODO (maybe): add YotaRuleConfig() as the first argument for consistency
    fn_name = :(ChainRulesCore.rrule)
    header = Expr(:call, fn_name)
    push!(header.args, Expr(:(::), :config, YotaRuleConfig))
    for v in inputs(tape)
        op = tape[v]
        push!(header.args, Expr(:(::), make_name(op), op.typ))
    end
    body = Expr(:block)
    # generate transformed forward pass
    seed_id = tape.meta[:seed].id
    for op in tape.ops[1:seed_id - 1]
        op isa Input && continue
        ex = to_expr(op)
        if ex isa Vector
            push!(body.args, ex...)
        else
            push!(body.args, ex)
        end
    end
    # generate pullback
    pb_name = gensym("pullback_$(tape[V(1)].val)")
    pb_ex = :(function $pb_name(dy) end)
    pb_body = pb_ex.args[2]
    empty!(pb_body.args)  # clean from useless linenumber nodes
    push!(pb_body.args, Expr(:(=), make_name(tape.meta[:seed].id), :dy))
    for op in tape.ops[seed_id + 1:length(tape) - 2]
        op isa Input && continue
        ex = to_expr(op)
        if ex isa Vector
            push!(pb_body.args, ex...)
        else
            push!(pb_body.args, ex)
        end
    end
    push!(body.args, pb_ex)
    # generate return
    result_name = make_name(tape[tape.result].args[1].id)
    push!(body.args, Expr(:tuple, result_name, pb_name))
    fn_ex = Expr(:function, header, body)
    return fn_ex
end


"""
    make_rrule(tape::Tape)
    make_rrule(f, args...)

Generate a function equivalent to (but not extending) ChainRulesCore.rrule(),
i.e. returning the primal value and the pullback.


Examples:
=========

    foo(x) = 2x + 1
    rr = make_rrule(foo, 2.0)
    val, pb = rr(foo, 3.0)
    pb(1.0)

"""
make_rrule(tape::Tape) = Base.eval(@__MODULE__, to_rrule_expr(tape))

function make_rrule(f, args...)
    tape = gradtape(f, args...; seed=:auto, ctx=GradCtx())
    return make_rrule(tape)
end

# function make_rrule(::typeof(broadcasted), f, args...)
#     if isprimitive(GradCtx(), f, map(first, args)...)
#         return bcast_rrule # (YOTA_RULE_CONFIG, broadcasted, f, args...)
#     end
#     ctx = BcastGradCtx(GradCtx())
#     _, tape = trace(f, args...; ctx=ctx)
#     tape = Tape(tape; ctx=ctx.inner)
#     gradtape!(tape, seed=:auto)
#     # insert imaginary broadcasted to the list of inputs
#     insert!(tape, 1, Umlaut.Input(broadcasted))
#     # insert ZeroTangent to the result to account for the additional argument
#     grad_tuple_op = tape[V(tape.result.id - 2)]
#     @assert grad_tuple_op isa Call && grad_tuple_op.fn == tuple
#     grad_tuple_op.args = [ZeroTangent(), grad_tuple_op.args...]
#     for id=grad_tuple_op.id:grad_tuple_op.id + 2
#         Umlaut.exec!(tape, tape[V(id)])
#     end
#     return make_rrule(tape)
# end


const GENERATED_RRULE_CACHE = Dict()
const RRULE_VIA_AD_STATE = Ref{Tuple}()


"""
    rrule_via_ad(::YotaRuleConfig, f, args...)

Generate `rrule` using Yota.
"""
function ChainRulesCore.rrule_via_ad(cfg::YotaRuleConfig, f, args...)
    arg_type_str = join(["::$(typeof(a))" for a in args], ", ")
    @debug "Running rrule_via_ad() for $f($arg_type_str)"
    res = rrule(cfg, f, args...)
    !isnothing(res) && return res
    @debug "No rrule in older world ages, falling back to invokelatest"
    res = Base.invokelatest(rrule, cfg, f, args...)
    # note: returned pullback is still in future, so we re-wrap it into invokelatest too
    !isnothing(res) && return res[1], dy -> Base.invokelatest(res[2], dy)
    @debug "No rrule in the latest world age, compiling a new one"
    make_rrule(f, args...)
    res = Base.invokelatest(rrule, cfg, f, args...)
    return res[1], dy -> Base.invokelatest(res[2], dy)
    # sig = map(typeof, (f, args...))
    # if false
    # if haskey(GENERATED_RRULE_CACHE, sig)
    #     @debug "Found rrule in cache"
    #     # rr = GENERATED_RRULE_CACHE[sig]
    #     # # return Base.invokelatest(rr, f, args...)
    #     # val, pb = Base.invokelatest(rr, YOTA_RULE_CONFIG, f, args...)
    #     # @debug "Done using cached rrule for $f($arg_type_str)"
    #     # return val, dy -> Base.invokelatest(pb, dy)
    #     tape = GENERATED_RRULE_CACHE[sig]
    #     return play!(tape, f, args...)
    # else
    #     try
    #         @debug "Generating a new rrule"
    #         # rr = make_rrule(f, args...)
    #         # GENERATED_RRULE_CACHE[sig] = rr
    #         # # return Base.invokelatest(rr, f, args...)
    #         # val, pb = Base.invokelatest(rr, YOTA_RULE_CONFIG, f, args...)
    #         # @debug "Done generating rrule for $f($arg_type_str)"
    #         # return val, dy -> Base.invokelatest(pb, dy)
    #         tape = gradtape(f, args...; seed=:auto, ctx=GradCtx())
    #         GENERATED_RRULE_CACHE[sig] = tape
    #         return play!(tape, f, args...)
    #     catch
    #         RRULE_VIA_AD_STATE[] = (f, args)
    #         @error("Failed to compile rrule for $(f)$args, extract details via:\n" *
    #              "\t(f, args) = Yota.RRULE_VIA_AD_STATE[]")
    #         rethrow()
    #     end
    # end
end