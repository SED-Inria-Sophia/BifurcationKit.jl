abstract type AbstractBoundaryValueProblem <: AbstractBifurcationProblem end
abstract type AbstractPeriodicOrbitProblem <: AbstractBoundaryValueProblem end

# Periodic orbit computations by finite differences
abstract type AbstractPODiffProblem <: AbstractPeriodicOrbitProblem end
abstract type AbstractPOFDProblem <: AbstractPODiffProblem end
# Periodic orbit computations by shooting
abstract type AbstractShootingProblem <: AbstractPeriodicOrbitProblem end
abstract type AbstractPoincareShootingProblem <: AbstractShootingProblem end
# wrapper problems
abstract type AbstractWrapperPOProblem <: AbstractPeriodicOrbitProblem end
abstract type AbstractWrapperShootingProblem <: AbstractWrapperPOProblem end
abstract type AbstractWrapperFDProblem <: AbstractWrapperPOProblem end

# get the number of time slices
@inline get_mesh_size(pb::AbstractPeriodicOrbitProblem) = pb.M

"""
$(SIGNATURES)

Compute the period of the periodic orbit associated to `x`.
"""
@inline getperiod(::AbstractPeriodicOrbitProblem, x, par = nothing) = extract_period(x)
@inline getperiod(prob::WrapPOColl, u, p) = getperiod(prob.prob, u, p)
@inline getperiod(prob::WrapPOSh, u, p) = getperiod(prob.prob, u, p)
@inline extract_period(x::AbstractVector) = x[end]
@inline extract_period(x::BorderedArray)  = x.p
set_params_po(pb::AbstractPODiffProblem, pars) = (@set pb.prob_vf = re_make(pb.prob_vf; params = pars))
set_params_po(pb::AbstractShootingProblem, pars) = (@set pb.par = pars)

get_periodic_orbit(prob::WrapPOColl, u, p) = get_periodic_orbit(prob.prob, u, p)
get_periodic_orbit(prob::WrapPOSh, u, p) = get_periodic_orbit(prob.prob, u, p)
# function to extract trajectories from branch
get_periodic_orbit(br::AbstractBranchResult, ind::Int) = get_periodic_orbit(br.prob, br.sol[ind].x, setparam(br, br.sol[ind].p))
@inline getdelta(prob::WrapPOSh) = getdelta(prob.prob.flow)
@inline has_hessian(::WrapPOSh) = true

Base.size(pb::AbstractPOFDProblem) = (pb.M, pb.N)
on_gpu(pb::AbstractPOFDProblem) = pb.ongpu
has_hessian(pb::AbstractPOFDProblem) = pb.d2F == nothing
isinplace(pb::AbstractPOFDProblem) = isinplace(pb.prob_vf)

function applyJ(pb, dest, x, p, dx)
    if isinplace(pb)
        pb.prob_vf.VF.J(dest, x, p, dx)
    else
        dest .= apply(pb.prob_vf.VF.J(x, p), dx)
    end
    dest
end

"""
$(SIGNATURES)

This function generates an initial guess for the solution of the problem `pb` based on the orbit `t -> orbit(t)` for t ∈ [0, 2π] and the period `period`.
"""
function generate_solution(pb::AbstractPeriodicOrbitProblem, orbit, period)
    M = get_mesh_size(pb)
    orbitguess_a = [orbit(t) for t in LinRange(0, 2pi, M + 1)[1:M]]
    # append period at the end of the initial guess
    orbitguess_v = reduce(vcat, orbitguess_a)
    if pb  isa PoincareShootingProblem
        return vec(orbitguess_v)
    else
        return vcat(vec(orbitguess_v), period) |> vec
    end
end

"""
Structure to encode the solution associated to a functional like `::PeriodicOrbitOCollProblem` or `::ShootingProblem`. In the particular case of `::PeriodicOrbitOCollProblem`, this allows to use the collocation polynomials to interpolate the solution. Hence, if `sol::POSolution`, then one can call

    sol = BifurcationKit.POSolution(prob_coll, x)
    sol(t)

on any time `t`.
"""
struct POSolution{Tpb, Tx, Tp}
    pb::Tpb
    x::Tx
    pars::Tp
end
POSolution(prob::AbstractPeriodicOrbitProblem, x) = POSolution(prob, x, nothing)
####################################################################################################
# structure to save solution on the branch
save_solution(::WrapPOSh, x, p) = x

"""
Structure to save a solution from a PO functional on the branch. This is useful for branching in case of mesh adaptation or when the phase condition is adapted.
"""
struct POSolutionAndState{T1, T2, T3, T4}
    mesh::T1
    sol::T2
    _mesh::T3
    ϕ::T4
end
@inline _getsolution(x) = x
@inline _getsolution(pb::POSolutionAndState) = pb.sol
####################################################################################################
"""
This struct allows to have a unified interface with Shooting methods in term of plotting.
"""
@with_kw_noshow struct SolPeriodicOrbit{Ts, Tu}
    t::Ts
    u::Tu
end
Base.getindex(sol::SolPeriodicOrbit, i...) = getindex(sol.u, i...)
Base.axes(sol::SolPeriodicOrbit, i) = axes(sol.u, i)
####################################################################################################
"""
$(TYPEDEF)

Define a structure to interface the jacobian of the periodic orbits functional with the Floquet computation methods. If we use the same code as for `newton` (see below) but in `continuation`, it is difficult to tell to the eigensolver that it should use the monodromy matrix instead of the jacobian.

## Methods
- `_get_matrix(::FloquetWrapper)`
- `apply(shjac::FloquetWrapper, dx)`

## Fields
$(TYPEDFIELDS)
"""
mutable struct FloquetWrapper{Tpb, Tjacpb, Torbitguess, Tp}
    pb::Tpb
    jacpb::Tjacpb
    x::Torbitguess
    par::Tp
end
FloquetWrapper(pb, x, par) = FloquetWrapper(pb, dx -> pb(x, par, dx), x, par)
_get_matrix(pb::AbstractMatrix) = pb
_get_matrix(pb::FloquetWrapper) = pb.jacpb

# jacobian evaluation
(shjac::FloquetWrapper)(dx) = apply(shjac.jacpb, dx)

# this is to use with BorderingBLS with check_precision = true
apply(shjac::FloquetWrapper, dx) = apply(shjac.jacpb, dx)

# specific linear solver to dispatch
"""
$(TYPEDEF)

Define a structure to interface the linear solver with the type `FloquetWrapper`.

## Methods
- `LinearAlgebra.hcat(::FloquetWrapper, dR)`

## Fields
$(TYPEDFIELDS)
"""
struct FloquetWrapperLS{T} <: AbstractLinearSolver
    solver::T # the use of field `solver` is good for BLS
end
# this constructor prevents from having FloquetWrapperLS(FloquetWrapperLS(ls))
FloquetWrapperLS(ls::FloquetWrapperLS) = ls
(ls::FloquetWrapperLS)(J, rhs; kwargs...) = ls.solver(J, rhs; kwargs...)
(ls::FloquetWrapperLS)(J::FloquetWrapper, rhs; kwargs...) = ls.solver(J.jacpb, rhs; kwargs...)
(ls::FloquetWrapperLS)(J::FloquetWrapper, rhs1, rhs2) = ls.solver(J.jacpb, rhs1, rhs2)

# this is to use of MatrixBLS
LinearAlgebra.hcat(shjac::FloquetWrapper, dR) = hcat(shjac.jacpb, dR)
####################################################################################################
const DocStringJacobianPOSh = """
- `jacobian` Specify the choice of the linear algorithm, which must belong to `[AutoDiffMF(), MatrixFree(), AutodiffDense(), AutoDiffDenseAnalytical(), FiniteDifferences(), FiniteDifferencesMF()]`. This is used to select a way of inverting the jacobian dG
    - For `MatrixFree()`, matrix free jacobian, the jacobian is specified by the user in `prob`. This is to be used with an iterative solver (e.g. GMRES) to solve the linear system
    - For `AutoDiffMF()`, we use Automatic Differentiation (AD) to compute the (matrix-free) derivative of `x -> prob(x, p)` using a directional derivative. This is to be used with an iterative solver (e.g. GMRES) to solve the linear system
    - For `AutodiffDense()`. Same as for `AutoDiffMF` but the jacobian is formed as a dense Matrix. You can use a direct solver or an iterative one.
    - For `FiniteDifferences()`, same as for `AutoDiffDense` but we use Finite Differences to compute the jacobian of `x -> prob(x, p)` using the `δ = 1e-8` which can be passed as an argument.
    - For `AutoDiffDenseAnalytical()`. Same as for `AutoDiffDense` but the jacobian is formed using a mix of AD and analytical formula.
    - For `FiniteDifferencesMF()`, use Finite Differences to compute the matrix-free jacobian of `x -> prob(x, p)` using the `δ = 1e-8` which can be passed as an argument.
"""
##########################
residual(prob::WrapPOSh, x, p) = prob.prob(x, p)
jacobian(prob::WrapPOSh, x, p) = prob.jacobian(x, p)
@inline is_symmetric(prob::WrapPOSh) = false

function _generate_jacobian(prob::AbstractShootingProblem, orbitguess, par; δ = convert(eltype(orbitguess), 1e-8))
    jacobianPO = prob.jacobian
    if jacobianPO isa AutoDiffDenseAnalytical
        _J = prob(Val(:JacobianMatrix), orbitguess, par)
        jac = (x, p) -> prob(Val(:JacobianMatrixInplace), _J, x, p)
    elseif jacobianPO isa AutoDiffDense
        jac = (x, p) -> ForwardDiff.jacobian(z -> prob(z, p), x)
    elseif jacobianPO isa AutoDiffMF
        jac = (x, p) -> (dx -> ForwardDiff.derivative(z -> prob((@. x + z * dx), p), 0))
    elseif jacobianPO isa FiniteDifferences
        jac = (x, p) -> finite_differences(z -> prob(z, p), x; δ = δ)
    elseif jacobianPO isa FiniteDifferencesMF
        jac = (x, p) -> dx -> (prob(x .+ δ .* dx, p) .- prob(x .- δ .* dx, p)) ./ (2δ)
    else
        jac = (x, p) -> (dx -> prob(x, p, dx))
    end
end

"""
$(SIGNATURES)

This is the Newton-Krylov Solver for computing a periodic orbit using the (Standard / Poincaré) Shooting method.
Note that the linear solver has to be appropriately set up in `options`.

# Arguments

Similar to [`newton`](@ref) except that `prob` is either a [`ShootingProblem`](@ref) or a [`PoincareShootingProblem`](@ref). These two problems have specific options to be tuned, we refer to their link for more information and to the tutorials.

- `prob` a problem of type `<: AbstractShootingProblem` encoding the shooting functional G.
- `orbitguess` a guess for the periodic orbit. See [`ShootingProblem`](@ref) and See [`PoincareShootingProblem`](@ref) for information regarding the shape of `orbitguess`.
- `par` parameters to be passed to the functional
- `options` same as for the regular [`newton`](@ref) method.

# Optional argument
$DocStringJacobianPOSh
"""
function newton(prob::AbstractShootingProblem,
                orbitguess,
                options::NewtonPar;
                lens::Union{AllOpticTypes, Nothing} = nothing,
                δ = convert(eltype(orbitguess), 1e-8),
                kwargs...)
    jac = _generate_jacobian(prob, orbitguess, getparams(prob); δ = δ)
    probw = WrapPOSh(prob, jac, orbitguess, getparams(prob), lens, nothing, nothing)
    return solve(probw, Newton(), options; kwargs...)
end

"""
$(SIGNATURES)

This is the deflated Newton-Krylov Solver for computing a periodic orbit using a (Standard / Poincaré) Shooting method.

# Arguments

Similar to [`newton`](@ref) except that `prob` is either a [`ShootingProblem`](@ref) or a [`PoincareShootingProblem`](@ref).

# Optional argument
$DocStringJacobianPOSh

# Output:
- solution::NonLinearSolution, see [`NonLinearSolution`](@ref)
"""
function newton(prob::AbstractShootingProblem,
                orbitguess::vectype,
                defOp::DeflationOperator{Tp, Tdot, T, vectype},
                options::NewtonPar{T, S, E};
                lens::Union{AllOpticTypes, Nothing} = nothing,
                kwargs...,
            ) where {T, Tp, Tdot, vectype, S, E}
    jac = _generate_jacobian(prob, orbitguess, getparams(prob))
    probw = WrapPOSh(prob, jac, orbitguess, getparams(prob), lens, nothing, nothing)
    return solve(probw, defOp, options; kwargs...)
end

####################################################################################################
# Continuation for shooting problems
function generate_jacobian(probPO::AbstractShootingProblem, 
                        orbitguess, 
                        par;
                        δ = convert(eltype(orbitguess), 1e-8))
    jacobianPO = probPO.jacobian
    @assert jacobianPO in (AutoDiffMF(), MatrixFree(), AutoDiffDense(), AutoDiffDenseAnalytical(), FiniteDifferences(), FiniteDifferencesMF()) "This jacobian is not defined. Please chose another one."
    if jacobianPO isa AutoDiffDenseAnalytical
        _J = probPO(Val(:JacobianMatrix), orbitguess, getparams(probPO))
        jac = (x, p) -> (probPO(Val(:JacobianMatrixInplace), _J, x, p); FloquetWrapper(probPO, _J, x, p));
    elseif jacobianPO isa AutoDiffDense
        jac = (x, p) -> FloquetWrapper(probPO, ForwardDiff.jacobian(z -> probPO(z, p), x), x, p)
    elseif jacobianPO isa FiniteDifferences
        jac = (x, p) -> FloquetWrapper(probPO, finite_differences(z -> probPO(z, p), x), x, p)
    elseif jacobianPO isa AutoDiffMF
        jac = (x, p) -> FloquetWrapper(probPO, (dx -> ForwardDiff.derivative(z -> probPO(x .+ z .* dx, p), 0)), x, p)
    elseif jacobianPO isa FiniteDifferencesMF
        jac = (x, p) -> FloquetWrapper(probPO, dx -> (probPO(x .+ δ .* dx, p) .- probPO(x .- δ .* dx, p)) ./ (2δ), x, p)
    else
        jac = (x, p) -> FloquetWrapper(probPO, x, p)
    end
end

"""
$(SIGNATURES)

This is the continuation method for computing a periodic orbit using a (Standard / Poincaré) Shooting method.

# Arguments

Similar to [`continuation`](@ref) except that `probPO` is either a [`ShootingProblem`](@ref) or a [`PoincareShootingProblem`](@ref). By default, it prints the period of the periodic orbit.

# Optional arguments
- `eigsolver` specify an eigen solver for the computation of the Floquet exponents, defaults to `FloquetQaD`
$DocStringJacobianPOSh
"""
function continuation(probPO::AbstractShootingProblem,
                        orbitguess,
                        alg::AbstractContinuationAlgorithm,
                        contParams::ContinuationPar,
                        linear_algo::AbstractBorderedLinearSolver;
                        δ = convert(eltype(orbitguess), 1e-8),
                        eigsolver = FloquetQaD(contParams.newton_options.eigsolver),
                        record_from_solution = nothing,
                        plot_solution = nothing,
                        kwargs...)
    jacobianPO = probPO.jacobian
    @assert ~isnothing(getlens(probPO)) "You need to provide a lens for your periodic orbit problem."

    jac = generate_jacobian(probPO, orbitguess, getparams(probPO); δ)

    if compute_eigenelements(contParams)
        contParams = @set contParams.newton_options.eigsolver = eigsolver
    end

    # change the user provided functions by passing probPO in its parameters
    _finsol = modify_po_finalise(probPO, kwargs, probPO.update_section_every_step)
    # remove this part from the arguments passed to continuation
    _kwargs = (record_from_solution = record_from_solution, plot_solution = plot_solution)
    _recordsol = modify_po_record(probPO, _kwargs, getparams(probPO), getlens(probPO))
    _plotsol   = modify_po_plot(probPO, _kwargs)

    # we have to change the Bordered linearsolver to cope with our type FloquetWrapper
    linear_algo = @set linear_algo.solver = FloquetWrapperLS(linear_algo.solver)
    alg = update(alg, contParams, linear_algo)

    probwp = WrapPOSh(probPO, jac, orbitguess, getparams(probPO), getlens(probPO), _plotsol, _recordsol)
    options = contParams.newton_options

    br = continuation(
        probwp, alg,
        (@set contParams.newton_options.linsolver = FloquetWrapperLS(options.linsolver));
        kwargs...,
        kind = PeriodicOrbitCont(),
        finalise_solution = _finsol)
    return br
end

"""
$(SIGNATURES)

This is the continuation routine for computing a periodic orbit using a (Standard / Poincaré) Shooting method.

# Arguments

Similar to [`continuation`](@ref) except that `prob` is either a [`ShootingProblem`](@ref) or a [`PoincareShootingProblem`](@ref). By default, it prints the period of the periodic orbit.

# Optional argument
- `linear_algo::AbstractBorderedLinearSolver`
$DocStringJacobianPOSh

"""
function continuation(prob::AbstractPeriodicOrbitProblem,
                    orbitguess,
                    alg::AbstractContinuationAlgorithm,
                    _contParams::ContinuationPar;
                    linear_algo = nothing,
                    kwargs...)
    _linear_algo = isnothing(linear_algo) ?  MatrixBLS() : linear_algo
    return continuation(prob, orbitguess, alg, _contParams, _linear_algo; kwargs...)
end

####################################################################################################
"""
$(SIGNATURES)

Perform automatic branch switching from a Hopf bifurcation point labelled `ind_bif` in the list of the bifurcated points of a previously computed branch `br::ContResult`. It first computes a Hopf normal form.

# Arguments

- `br` branch result from a call to `continuation`
- `ind_hopf` index of the bifurcation point in `br`
- `contParams` parameters for the call to `continuation`
- `probPO` problem used to specify the way the periodic orbit is computed. It can be [`PeriodicOrbitTrapProblem`](@ref), [`ShootingProblem`](@ref) or [`PoincareShootingProblem`](@ref) .

# Optional arguments

- `alg = br.alg` continuation algorithm
- `δp` used to specify a particular guess for the parameter on the bifurcated branch which is otherwise determined by `contParams.ds`. This allows to use a step larger than `contParams.dsmax`.
- `ampfactor = 1` factor to alter the amplitude of the bifurcated solution. Useful to magnify the bifurcated solution when the bifurcated branch is very steep.
- `usedeflation = true` whether to use nonlinear deflation (see [Deflated problems](@ref)) to help finding the guess on the bifurcated branch
- `use_normal_form = true` compute the normal form to get the predictor. When `false`, `ampfactor` and `δp` are used to make a predictor based on the eigenvector. This can be useful when computing the normal form is not possible for example when higher order derivatives are not available.
- `nev` number of eigenvalues to be computed to get the right eigenvector
- `autodiff_nf = true` use `autodiff` in `get_normal_form`?
- all `kwargs` from [`continuation`](@ref)

A modified version of `prob` is passed to `plot_solution` and `finalise_solution`.

!!! note "Linear solver"
    You have to be careful about the options `contParams.newton_options.linsolver`. In the case of Matrix-Free solver, you have to pass the right number of unknowns `N * M + 1`. Note that the options for the preconditioner are not accessible yet.
"""
function continuation(br::AbstractBranchResult, 
                      ind_bif::Int,
                      _contParams::ContinuationPar,
                      pbPO::AbstractPeriodicOrbitProblem ;
                      prob_vf = br.prob,
                      alg = getalg(br),
                      δp = nothing,
                      ampfactor = 1,
                      usedeflation = false,
                      use_normal_form = true,
                      autodiff_nf = true,
                      nev = length(eigenvalsfrombif(br, ind_bif)),
                      kwargs...)
    # compute the normal form of the branch point
    verbose = get(kwargs, :verbosity, 0) > 1
    verbose && (println("──▶ Considering bifurcation point:"); _show(stdout, br.specialpoint[ind_bif], ind_bif))

    cb = get(kwargs, :callback_newton, cb_default)

    hopfpt = hopf_normal_form(prob_vf, br, ind_bif; nev, verbose, detailed = use_normal_form, autodiff = autodiff_nf)

    # compute predictor for point on new branch
    ds = isnothing(δp) ? _contParams.ds : δp
    𝒯 = typeof(ds)
    pred = predictor(hopfpt, ds; verbose, ampfactor = 𝒯(ampfactor))

    # we compute a phase so that the constraint equation
    # < u(0) − u_hopf, ψ > is satisfied, i.e. equal to zero.
    ζr = real.(hopfpt.ζ)
    ζi = imag.(hopfpt.ζ)
    # this phase is for POTrap problem constraint to be satisfied
    ϕ = atan(dot(ζr, ζr), dot(ζi, ζr))

    verbose && printstyled(color = :green, "━"^55*
            "\n┌─ Start branching from Hopf bif. point to periodic orbits.",
            "\n├─ Bifurcation type = ", hopfpt.type,
            "\n├─── Hopf param  p0 = ", br.specialpoint[ind_bif].param,
            "\n├─── new param    p = ", pred.p, ", p - p0 = ", pred.p - br.specialpoint[ind_bif].param,
            "\n├─── amplitude p.o. = ", pred.amp,
            "\n├─── period       T = ", pred.period,
            "\n├─── phase        ϕ = ", ϕ / pi, "⋅π",
            "\n├─ Method = \n", pbPO, "\n")

    if pred.amp > 0.1
        @debug "The guess for the amplitude of the first periodic orbit on the bifurcated branch obtained by the predictor is not small: $(pred.amp). This may lead to convergence failure of the first newton step or select a branch far from the Hopf point.\nYou can either decrease `ds` or `δp` (which is  how far from the bifurcation point you want the branch of periodic orbits to start). Alternatively, you can specify a multiplicative factor `ampfactor` to be applied to the predictor amplitude."
    end

    M = get_mesh_size(pbPO)
    orbitguess_a = [pred.orbit(t - ϕ) for t in LinRange(0, 2pi, M + 1)[1:M]]

    # extract the vector field and use it possibly to affect the PO functional
    prob_vf_rm = re_make(prob_vf, params = setparam(br, pred.p))

    # build the variable to hold the functional for computing PO based on finite differences
    probPO, orbitguess = re_make(pbPO, prob_vf_rm, hopfpt, ζr, orbitguess_a, abs(2pi/pred.ω); orbit = pred.orbit)

    if _contParams.newton_options.linsolver isa GMRESIterativeSolvers
        _contParams = @set _contParams.newton_options.linsolver.N = length(orbitguess)
    end

    if usedeflation
        verbose &&
            println("\n├─ Attempt branch switching\n──> Compute point on the current branch...")
        probPO isa PoincareShootingProblem &&
            @warn "Poincaré Shooting does not work very well with stationary states."
        optn = _contParams.newton_options

        # we start with the case of zero amplitude
        orbitzeroamp_a = [hopfpt.x0 for _ = 1:M]
        # this factor prevent shooting jacobian from being singular at fixed points
        if probPO isa PoincareShootingProblem
            Tfactor = 0
        elseif probPO isa AbstractPOFDProblem
            Tfactor = 100 / abs(2pi / pred.ω)
        else
            Tfactor = 0.001
        end

        # TODO should only update guess here, cf Poincaré
        probPO0, orbitzeroamp = re_make(probPO, prob_vf, hopfpt, ζr, orbitzeroamp_a, 𝒯(Tfactor * abs(2pi / pred.ω)))
        sol0 = newton(probPO0, orbitzeroamp, optn; callback = cb, kwargs...)

        # find the bifurcated branch using deflation
        if ~(probPO isa PoincareShootingProblem)
            deflationOp = DeflationOperator(2, (x, y) -> dot(x[1:end-1], y[1:end-1]), one(𝒯), [sol0.u]; autodiff = true)
        else
            deflationOp = DeflationOperator(2, (x, y) -> dot(x, y) / M, one(𝒯), [sol0.u]; autodiff = true)
        end

        verbose && println("\n──▶ Compute point on bifurcated branch...")
        solbif = newton(probPO, orbitguess, deflationOp, (@set optn.max_iterations = 10 * optn.max_iterations); callback = cb, kwargs...)
        @assert converged(solbif) "Deflated newton did not converge"
        orbitguess .= solbif.u

        branch = continuation(
            probPO, orbitguess, alg,
            _contParams;
            kwargs...,
        )

        return Branch(branch, hopfpt)
    end

    # perform continuation
    branch = continuation(
        probPO, orbitguess, alg,
        _contParams;
        kwargs...
    )

    return Branch(branch, hopfpt)
end

####################################################################################################
# Branch switching from bifurcations of periodic orbits
"""
$(SIGNATURES)

Branch switching at a bifurcation point on a branch of periodic orbits (PO) specified by a `br::AbstractBranchResult`. The functional used to compute the PO is `br.prob`. A deflated Newton-Krylov solver can be used to improve the branch switching capabilities.

# Arguments
- `br` branch of periodic orbits computed with a [`PeriodicOrbitTrapProblem`](@ref)
- `ind_bif` index of the branch point
- `_contParams` parameters to be used by a regular [`continuation`](@ref)

# Optional arguments
- `δp = 0.1` used to specify a particular guess for the parameter in the branch which is otherwise determined by `contParams.ds`. This allows to use a step larger than `contParams.dsmax`.
- `ampfactor = 1` factor which alters the amplitude of the bifurcated solution. Useful to magnify the bifurcated solution when the bifurcated branch is very steep.
- `usedeflation = true` whether to use nonlinear deflation (see [Deflated problems](@ref)) to help finding the guess on the bifurcated branch

## For normal form
- `detailed = false` whether to fully compute the normal form.
- `record_from_solution = (u, p) -> u[end]`, record method used in the bifurcation diagram, by default this records the period of the periodic orbit.

## For continuation
- `linear_algo = BorderingBLS()`, same as for [`continuation`](@ref)
- `kwargs` keywords arguments used for a call to the regular [`continuation`](@ref) and the ones specific to periodic orbits (POs).
"""
function continuation(br::AbstractResult{PeriodicOrbitCont, Tprob},
                    ind_bif::Int,
                    _contParams::ContinuationPar;
                    alg = getalg(br),
                    δp = _contParams.ds, 
                    ampfactor = 1,
                    usedeflation = false,
                    linear_algo = nothing,
                    detailed = true,
                    prm = getprob(br) isa WrapPOColl ? false : true,
                    use_normal_form = true,
                    kwargs...) where Tprob

    bifpt = br.specialpoint[ind_bif]
    bptype = bifpt.type
    @assert bptype in (:pd, :bp) "Branching from $(bptype) not possible yet."
    @assert abs(bifpt.δ[1]) == 1 "Only simple bifurcation points are handled"

    # we copy the problem for not mutating the one passed by the user. This is an AbstractPeriodicOrbitProblem.
    pb = deepcopy(br.prob.prob)

    nf = get_normal_form(br, ind_bif; detailed, prm)
    pred = predictor(nf, δp, ampfactor; override = ~use_normal_form)
    orbitguess = pred.orbitguess
    newp = pred.pnew  # new parameter value
    pbnew = pred.prob # modified problem

    verbose = get(kwargs, :verbosity, 0) > 0
    verbose && printstyled(color = :green, "━"^55*
            "\n┌─ Start branching from $(bptype) point to periodic orbits.\n├─ Bifurcation type = ", bifpt.type, " [NF based on = $(prm ? "Poincaré" : "Iooss")]",
            "\n├─── bif. param  p0 = ", bifpt.param,
            "\n├─── period at bif. = ", getperiod(br.prob.prob, bifpt.x, setparam(br, bifpt.param)),
            "\n├─── new param    p = ", newp, ", p - p0 = ", newp - bifpt.param,
            "\n└─── amplitude p.o. = ", pred.ampfactor,
            "\n")

    if pred.ampfactor > 0.1
        @warn "The amplitude of the first periodic orbit on the bifurcated branch\nobtained by the predictor is not small, it is = $(pred.ampfactor).\nYou can either decrease `ds`, or specify how far `δp` from the\nbifurcation point you want the branch of periodic orbits to start."
    end

    # a priori, the following do not overwrite the options in br
    # hence the results / parameters in br are kept intact)
    _contParams = _update_cont_params(_contParams, pbnew, orbitguess)

    if usedeflation
        verbose && println("\n├─ Attempt branch switching\n──> Compute point on the current branch...")
        optn = _contParams.newton_options
        # find point on the first branch
        pbnew = set_params_po(pbnew, setparam(br, newp))
        sol0 = newton(pbnew, pred.po, optn; kwargs...)
        @assert converged(sol0) "The first guess did not converge"

        # find the bifurcated branch using deflation
        deflationOp = DeflationOperator(2, (x, y) -> dot(x[begin:end-1], y[begin:end-1]), one(eltype(orbitguess)), [sol0.u]; autodiff = true)
        verbose && println("\n──> Compute point on the bifurcated branch...")
        solbif = newton(pbnew, orbitguess, deflationOp,
            (@set optn.max_iterations = 10 * optn.max_iterations) ; kwargs...,)
        @assert converged(solbif) "Deflated newton did not converge"
        orbitguess .= solbif.u
    end

    # perform continuation
    pbnew = set_params_po(pbnew, setparam(br, newp))

    residual(pbnew, orbitguess, setparam(br, newp))[end] |> abs > 1 && @warn "PO constraint not satisfied"

    _linear_algo = isnothing(linear_algo) ? BorderingBLS(_contParams.newton_options.linsolver) : linear_algo

    branch = continuation( pbnew, orbitguess, alg, _contParams;
        kwargs..., # put this first to be overwritten just below!
        linear_algo = _linear_algo,
        kind = br.kind
    )

    return Branch(branch, nf)
end
