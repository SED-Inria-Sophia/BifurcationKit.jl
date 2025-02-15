abstract type AbstractEvent end
abstract type AbstractContinuousEvent <: AbstractEvent end
abstract type AbstractDiscreteEvent <: AbstractEvent end

# evaluate the functional whose events are sought. It must return a Tuple.
(eve::AbstractEvent)(iter, state) = eve.condition(iter, state)

# initialize function, must return the same type as eve(iter, state)
initialize(eve::AbstractEvent, T) = throw("Initialization method not implemented for event ", eve)

# finalise event
finalise_event!(event_point, eve::AbstractEvent, it, state, success) = event_point
default_finalise_event!(event_point, it, state, success) = event_point

# whether the event requires computing eigen-elements
@inline compute_eigen_elements(::AbstractEvent) = false

length(::AbstractEvent) = throw("length not implemented")

# default label used to record event in ContResult
labels(::AbstractEvent, ind) = "user"

# whether the user provided its own labels
has_custom_labels(::AbstractEvent) = false

# general condition for detecting a continuous event.
function test_event(eve::AbstractContinuousEvent, x, y)
    ϵ = eve.tol
    return (x * y < 0) || (abs(x) <= ϵ) || (abs(y) <= ϵ)
end

# is x actually an event
function isonevent(eve::AbstractContinuousEvent, eventValue) 
    for u in eventValue
        if  abs(u) <= eve.tol
            return true
        end
    end
    return false
end

# Basically, we want to detect if some component of `eve(fct(iter, state))` is below ϵ
# the ind is used to specify which part of the event is tested
function is_event_crossed(eve::AbstractContinuousEvent, iter, state, ind = :)
    if state.eventValue[1] isa Real
        return test_event(eve, state.eventValue[1], state.eventValue[2])
    else
        for u in zip(state.eventValue[1][ind], state.eventValue[2][ind])
            if test_event(eve, u[1], u[2])
                return true
            end
        end
        return false
    end
end

# general condition for detecting a discrete event
test_event(eve::AbstractDiscreteEvent, x, y) = x != y
isonevent(::AbstractDiscreteEvent, x) = false

function is_event_crossed(eve::AbstractDiscreteEvent, iter, state, ind = :)
    if state.eventValue[1] isa Integer
        return test_event(eve, state.eventValue[1], state.eventValue[2])
    else
        for u in zip(state.eventValue[1][ind], state.eventValue[2][ind])
            if test_event(eve, u[1], u[2])
                return true
            end
        end
        return false
    end
end
####################################################################################################
# for AbstractContinuousEvent and AbstractDiscreteEvent
# return type when calling eve.fct(iter, state)
initialize(eve::AbstractContinuousEvent, T) = ntuple(x -> T(1), eve.nb)
initialize(eve::AbstractDiscreteEvent, T) = ntuple(x -> Int64(1), eve.nb)

@inline convert_to_tuple_eve(x::Tuple) = x
@inline convert_to_tuple_eve(x::Real) = (x,)
####################################################################################################
"""
$(TYPEDEF)

Structure to pass a ContinuousEvent function to the continuation algorithm.
A continuous call back returns a **tuple/scalar** value and we seek its zeros.

$(TYPEDFIELDS)
"""
struct ContinuousEvent{Tcb, Tl, T, Tf, Td} <: AbstractContinuousEvent
    "number of events, ie the length of the result returned by the callback function"
    nb::Int64

    ", ` (iter, state) -> NTuple{nb, T}` callback function which, at each continuation state, returns a tuple. For example, to detect crossing at 1.0 and at -2.0, you can pass `(iter, state) -> (getp(state)+2, getx(state)[1]-1)),`. Note that the type `T` should match the one of the parameter specified by the `::Lens` in `continuation`."
    condition::Tcb

    "whether the event requires to compute eigen elements"
    computeEigenElements::Bool

    "Labels used to display information. For example `labels[1]` is used to qualify an event of the type `(0, 1.3213, 3.434)`. You can use `labels = (\"hopf\",)` or `labels = (\"hopf\", \"fold\")`. You must have `labels::Union{Nothing, NTuple{N, String}}`."
    labels::Tl

    "Tolerance on event value to declare it as true event."
    tol::T

    "Finaliser function"
    finaliser::Tf

    "Place to store some personal data"
    data::Td

    function ContinuousEvent(nb::Int,
                            fct,
                            cev::Bool,
                            labels = nothing, 
                            tol::T = 0; 
                            finaliser::TF = default_finalise_event!, 
                            data::Td = nothing) where {T,TF,Td}
        @assert nb > 0 "You need to return at least one callback"
        condition = convert_to_tuple_eve ∘ fct
        new{typeof(condition), typeof(labels), T, TF, Td}(nb, condition, cev, labels, tol, finaliser, data)
    end
end

function ContinuousEvent(nb::Int, fct, labels = nothing; k...)
    ContinuousEvent(nb, fct, false, labels; k...)
end

@inline compute_eigenelements(eve::ContinuousEvent) = eve.computeEigenElements
@inline length(eve::ContinuousEvent) = eve.nb
@inline has_custom_labels(eve::ContinuousEvent{Tcb, Tl}) where {Tcb, Tl} = ~(Tl == Nothing)
finalise_event!(event_point, eve::ContinuousEvent, it, state, success) = eve.finaliser(event_point, it, state, success)
####################################################################################################
"""
$(TYPEDEF)

Structure to pass a DiscreteEvent function to the continuation algorithm.
A discrete call back returns a discrete value and we seek when it changes.

$(TYPEDFIELDS)
"""
struct DiscreteEvent{Tcb, Tl, Tf, Td} <: AbstractDiscreteEvent
    "number of events, ie the length of the result returned by the callback function"
    nb::Int64

    "= ` (iter, state) -> NTuple{nb, Int64}` callback function which at each continuation state, returns a tuple. For example, to detect a value change."
    condition::Tcb

    "whether the event requires to compute eigen elements"
    computeEigenElements::Bool

    "Labels used to display information. For example `labels[1]` is used to qualify an event occurring in the first component. You can use `labels = (\"hopf\",)` or `labels = (\"hopf\", \"fold\")`. You must have `labels::Union{Nothing, NTuple{N, String}}`."
    labels::Tl

    "Finaliser function"
    finaliser::Tf

    "Place to store some personal data"
    data::Td

    function DiscreteEvent(nb::Int,
                            fct,
                            cev::Bool,
                            labels = nothing; 
                            finaliser::TF = default_finalise_event!, 
                            data::Td = nothing) where {TF, Td}
        @assert nb > 0 "You need to return at least one callback"
        condition = convert_to_tuple_eve ∘ fct
        new{typeof(condition), typeof(labels), TF, Td}(nb, condition, cev, labels, finaliser, data)
    end
end

function DiscreteEvent(nb::Int, fct, labels = nothing; k...)
    DiscreteEvent(nb, fct, false, labels; k...)
end

@inline compute_eigenelements(eve::DiscreteEvent) = eve.computeEigenElements
@inline length(eve::DiscreteEvent) = eve.nb
@inline has_custom_labels(eve::DiscreteEvent{Tcb, Tl}) where {Tcb, Tl} = ~(Tl == Nothing)
finalise_event!(event_point, eve::DiscreteEvent, it, state, success) = eve.finaliser(event_point, it, state, success)

function labels(eve::Union{ContinuousEvent{Tcb, Nothing}, DiscreteEvent{Tcb, Nothing}}, ind) where Tcb
    if length(eve) == 1
        return "userC"
    else
        return "userC" * mapreduce(x -> "-$x", *, ind)
    end
end

function labels(eve::Union{ContinuousEvent{Tcb, Tl}, DiscreteEvent{Tcb, Tl}}, ind) where {Tcb, Tl}
    if isempty(ind)
        return "user"
    end
    return mapreduce(x -> eve.labels[x], *, ind)
end
####################################################################################################
"""
$(TYPEDEF)

Structure to pass a PairOfEvents function to the continuation algorithm. It is composed of a pair ContinuousEvent / DiscreteEvent. A `PairOfEvents`
is constructed by passing to the constructor a `ContinuousEvent` and a `DiscreteEvent`:

    PairOfEvents(contEvent, discreteEvent)

## Fields
$(TYPEDFIELDS)
"""
struct PairOfEvents{Tc <: AbstractContinuousEvent, Td <: AbstractDiscreteEvent}  <: AbstractEvent
    "Continuous event"
    eventC::Tc

    "Discrete event"
    eventD::Td
end

@inline compute_eigenelements(eve::PairOfEvents) = compute_eigenelements(eve.eventC) || compute_eigenelements(eve.eventD)
@inline length(event::PairOfEvents) = length(event.eventC) + length(event.eventD)
# is x actually an event, we just need to test the continuous part
isonevent(eve::PairOfEvents, x) = isonevent(eve.eventC, x[1:length(eve.eventC)])

function (eve::PairOfEvents)(iter, state)
    outc = eve.eventC(iter, state)
    outd = eve.eventD(iter, state)
    return outc..., outd...
end

initialize(eve::PairOfEvents, T) = initialize(eve.eventC, T)..., initialize(eve.eventD, T)...

function is_event_crossed(eve::PairOfEvents, iter, state, ind = :)
    nc = length(eve.eventC)
    n = length(eve)
    resC = is_event_crossed(eve.eventC, iter, state, 1:nc)
    resD = is_event_crossed(eve.eventD, iter, state, nc+1:n)
    return resC || resD
end

function finalise_event!(event_point, eve::PairOfEvents, it, state, success)
    event_point = finalise_event!(event_point, eve.eventC, it, state, success)
    finalise_event!(event_point, eve.eventD, it, state, success)
end
####################################################################################################
"""
$(TYPEDEF)

Multiple events can be chained together to form a `SetOfEvents`. A `SetOfEvents`
is constructed by passing to the constructor `ContinuousEvent`, `DiscreteEvent` or other `SetOfEvents` instances:

    SetOfEvents(cb1, cb2, cb3)

# Example

     BifurcationKit.SetOfEvents(BK.FoldDetectCB, BK.BifDetectCB)

You can pass as many events as you like.

$(TYPEDFIELDS)
"""
struct SetOfEvents{Tc <: Tuple, Td <: Tuple}  <: AbstractEvent
    "Continuous event"
    eventC::Tc

    "Discrete event"
    eventD::Td
end

SetOfEvents(callback::AbstractDiscreteEvent) = SetOfEvents((), (callback,))
SetOfEvents(callback::AbstractContinuousEvent) = SetOfEvents((callback,), ())
SetOfEvents() = SetOfEvents((), ())
SetOfEvents(cb::Nothing) = SetOfEvents()

# For Varargs, use recursion to make it type-stable
SetOfEvents(events::Union{AbstractEvent, Nothing}...) = SetOfEvents(split_events((), (), events...)...)

"""
    split_events(cs, ds, args...)
Split comma separated callbacks into sets of continuous and discrete callbacks. Inspired by DiffEqBase.
"""
@inline split_events(cs, ds) = cs, ds
@inline split_events(cs, ds, c::Nothing, args...) = split_events(cs, ds, args...)
@inline split_events(cs, ds, c::AbstractContinuousEvent, args...) = split_events((cs..., c), ds, args...)
@inline split_events(cs, ds, d::AbstractDiscreteEvent, args...) = split_events(cs, (ds..., d), args...)
@inline function split_events(cs, ds, d::SetOfEvents, args...)
  split_events((cs...,d.eventC...), (ds..., d.eventD...), args...)
end

@inline compute_eigenelements(eve::SetOfEvents) = mapreduce(compute_eigenelements, |, eve.eventC) || mapreduce(compute_eigenelements, |, eve.eventD)

function (eve::SetOfEvents)(iter, state)
    outc = map(x -> x(iter, state), eve.eventC)
    outd = map(x -> x(iter, state), eve.eventD)
    return (outc..., outd...)
end

initialize(eve::SetOfEvents, T) = map(x -> initialize(x,T), eve.eventC)..., 
                                  map(x -> initialize(x,T), eve.eventD)...

# is x actually an event, we just need to test the continuous events
function isonevent(eves::SetOfEvents, eValues)
    out = false
    for (index, eve) in pairs(eves.eventC)
        out = out | isonevent(eve, eValues[index])
    end
    return out
end  

function is_event_crossed(event::SetOfEvents, iter, state)
    res = false
    nC = length(event.eventC)
    nD = length(event.eventD)
    nCb = nC+nD
    for (i, eve) in enumerate(event.eventC)
        res = res | is_event_crossed(eve, iter, state, i)
    end
    for (i, eve) in enumerate(event.eventD)
        res = res | is_event_crossed(eve, iter, state, nC + i)
    end
    return  res
end

function finalise_event!(event_point, seve::SetOfEvents, it, state, success)
    for eve in seve.eventC
        event_point = finalise_event!(event_point, eve, it, state, success)
    end
    for eve in seve.eventD
        event_point = finalise_event!(event_point, eve, it, state, success)
    end
    event_point
end
