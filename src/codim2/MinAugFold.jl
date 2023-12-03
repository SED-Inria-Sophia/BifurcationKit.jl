"""
$(SIGNATURES)

For an initial guess from the index of a Fold bifurcation point located in ContResult.specialpoint, returns a point which will can refined using `newtonFold`.
"""
function foldpoint(br::AbstractBranchResult, index::Int)
    bptype = br.specialpoint[index].type
    @assert bptype == :bp || bptype == :nd || bptype == :fold "This should be a Fold / BP point"
    specialpoint = br.specialpoint[index]
    return BorderedArray(_copy(specialpoint.x), specialpoint.param)
end
####################################################################################################
@inline getvec(x, ::FoldProblemMinimallyAugmented) = get_vec_bls(x)
@inline getp(x, ::FoldProblemMinimallyAugmented) = get_par_bls(x)

function (𝐅::FoldProblemMinimallyAugmented)(x, p::𝒯, params) where 𝒯
    # These are the equations of the minimally augmented (MA) formulation of the Fold bifurcation point
    # input:
    # - x guess for the point at which the jacobian is singular
    # - p guess for the parameter value `<: Real` at which the jacobian is singular
    # The jacobian of the MA problem is solved with a BLS method
    # ┌      ┐┌  ┐   ┌ ┐
    # │ J  a ││v │ = │0│
    # │ b  0 ││σ │   │1│
    # └      ┘└  ┘   └ ┘
    # In the notations of Govaerts 2000, a = w, b = v
    # Thus, b should be a null vector of J
    #       a should be a null vector of J'
    # we solve Jv + a σ1 = 0 with <b, v> = 1
    # the solution is v = -σ1 J\a with σ1 = -1/<b, J^{-1}a>
    a = 𝐅.a
    b = 𝐅.b
    # update parameter
    par = set(params, getlens(𝐅), p)
    J = jacobian(𝐅.prob_vf, x, par)
    _, σ, cv, = 𝐅.linbdsolver(J, a, b, zero(𝒯), 𝐅.zero, one(𝒯))
    ~cv && @debug "Linear solver for J did not converge."
    return residual(𝐅.prob_vf, x, par), σ
end

# this function encodes the functional
function (𝐅::FoldProblemMinimallyAugmented)(x::BorderedArray, params)
    res = 𝐅(x.u, x.p, params)
    return BorderedArray(res[1], res[2])
end

@views function (𝐅::FoldProblemMinimallyAugmented)(x::AbstractVector, params)
    res = 𝐅(x[1:end-1], x[end], params)
    return vcat(res[1], res[2])
end

###################################################################################################
# Struct to invert the jacobian of the fold MA problem.
struct FoldLinearSolverMinAug <: AbstractLinearSolver; end

function foldMALinearSolver(x, p::𝒯, 𝐅::FoldProblemMinimallyAugmented, par,
                            rhsu, rhsp;
                            debugArray = nothing) where 𝒯
    ################################################################################################
    # debugArray is used as a temp to be filled with values used for debugging. If debugArray = nothing,
    # then no debugging mode is entered. If it is AbstractArray, then it is populated
    ################################################################################################
    # Recall that the functional we want to solve is [F(x,p), σ(x,p)] where σ(x,p) is computed in the 
    # function above. The Jacobian Jfold of the vector field is expressed at (x, p).
    # We solve Jfold⋅res = rhs := [rhsu, rhsp]
    # The Jacobian expression of the Fold problem is
    #           ┌         ┐
    #  Jfold =  │  J  dpF │
    #           │ σx   σp │
    #           └         ┘
    # where σx := ∂_xσ and σp := ∂_pσ
    # We recall the expression of
    #  σx = -< w, d2F(x,p)[v, x2]>
    # where (w, σ2) is solution of J'w + b σ2 = 0 with <a, w> = 1
    ########################## Extraction of function names ########################################
    a = 𝐅.a
    b = 𝐅.b

    # parameter axis
    lens = getlens(𝐅)
    # update parameter
    par0 = set(par, lens, p)

    # we compute the jacobian. It is used at least 3 times below. This avoids doing 3 times the 
    # (possibly) costly building of J(x, p)
    J_at_xp = jacobian(𝐅.prob_vf, x, par0)

    # we do the following in order to avoid computing J_at_xp twice in case 𝐅.Jadjoint is not provided
    if is_symmetric(𝐅.prob_vf)
        JAd_at_xp = J_at_xp
    else
        JAd_at_xp = has_adjoint(𝐅) ? jad(𝐅.prob_vf, x, par0) : transpose(J_at_xp)
    end

    # we solve Jv + a σ1 = 0 with <b, v> = 1
    # the solution is v = -σ1 J\a with σ1 = -1/<b, J\a>
    v, σ1, cv, itv = 𝐅.linbdsolver(J_at_xp, a, b, zero(𝒯), 𝐅.zero, one(𝒯))
    ~cv && @debug "Bordered linear solver for J did not converge. it = $(itv)"

    # we solve J'w + b σ2 = 0 with <a, w> = 1
    # the solution is w = -σ2 J'\b with σ2 = -1/<a, J'\b>
        w, σ2, cv, itw = 𝐅.linbdsolverAdjoint(JAd_at_xp, b, a, zero(𝒯), 𝐅.zero, one(𝒯))
        ~cv && @debug "Bordered linear solver for J' did not converge."

    δ = getdelta(𝐅.prob_vf)
    ϵ1, ϵ2, ϵ3 = 𝒯(δ), 𝒯(δ), 𝒯(δ)
    ################### computation of σx σp ####################
    ################### and inversion of Jfold ####################
    dpF = minus(residual(𝐅.prob_vf, x, set(par, lens, p + ϵ1)),
                residual(𝐅.prob_vf, x, set(par, lens, p - ϵ1))); rmul!(dpF, 𝒯(1 / (2ϵ1)))
    dJvdp = minus(apply(jacobian(𝐅.prob_vf, x, set(par, lens, p + ϵ3)), v),
                  apply(jacobian(𝐅.prob_vf, x, set(par, lens, p - ϵ3)), v));
    rmul!(dJvdp, 𝒯(1/(2ϵ3)))
    σp = -dot(w, dJvdp)

    if has_hessian(𝐅) == false || 𝐅.usehessian == false
        # We invert the jacobian of the Fold problem when the Hessian of x -> F(x, p) is not known analytically.
        # apply Jacobian adjoint
        u1 = apply_jacobian(𝐅.prob_vf, x + ϵ2 * v, par0, w, true)
        u2 = apply(JAd_at_xp, w)
        σx = minus(u2, u1); rmul!(σx, 1 / ϵ2)
        ########## Resolution of the bordered linear system ########
        # we invert Jfold
        dX, dsig, cv, it = 𝐅.linbdsolver(J_at_xp, dpF, σx, σp, rhsu, rhsp)
        ~cv && @debug "Bordered linear solver for J did not converge."
    else
        # We invert the jacobian of the Fold problem when the Hessian of x -> F(x, p) is known analytically.
        # we solve it here instead of calling linearBorderedSolver because this removes the need to pass the linear form associated to σx
        # !!! Careful, this method makes the linear system singular
        x1, x2, cv, it = 𝐅.linsolver(J_at_xp, rhsu, dpF)
        ~cv && @debug "Linear solver for J did not converge."

        d2Fv = d2F(𝐅.prob_vf, x, par0, x1, v)
        σx1 = -dot(w, d2Fv )

        copyto!(d2Fv, d2F(𝐅.prob_vf, x, par0, x2, v))
        σx2 = -dot(w, d2Fv )

        dsig = (rhsp - σx1) / (σp - σx2)

        # dX = @. x1 - dsig * x2
        dX = _copy(x1); axpy!(-dsig, x2, dX)
    end

    if debugArray isa AbstractArray
        debugArray .= [jacobian(𝐅.prob_vf, x, par0) dpF ; σx' σp]
    end

    return dX, dsig, true, sum(it) + sum(itv) + sum(itw)
end

function (foldl::FoldLinearSolverMinAug)(Jfold, du::BorderedArray{vectype, T}; debugArray = nothing, kwargs...) where {vectype, T}
    # kwargs is used by AbstractLinearSolver
    out = foldMALinearSolver((Jfold.x).u,
                 (Jfold.x).p,
                 Jfold.prob,
                 Jfold.params,
                 du.u, du.p;
                 debugArray = debugArray)
    # this type annotation enforces type stability
    return BorderedArray{vectype, T}(out[1], out[2]), out[3], out[4]
end
###################################################################################################
@inline has_adjoint(foldpb::FoldMAProblem) = has_adjoint(foldpb.prob)
@inline getdelta(foldpb::FoldMAProblem) = getdelta(foldpb.prob)
@inline is_symmetric(foldpb::FoldMAProblem) = is_symmetric(foldpb.prob)
residual(foldpb::FoldMAProblem, x, p) = foldpb.prob(x, p)
jad(foldpb::FoldMAProblem, args...) = jad(foldpb.prob, args...)

jacobian(foldpb::FoldMAProblem{Tprob, Nothing, Tu0, Tp, Tl, Tplot, Trecord}, x, p) where {Tprob, Tu0, Tp, Tl <: Union{Lens, Nothing}, Tplot, Trecord} = (x = x, params = p, prob = foldpb.prob)

jacobian(foldpb::FoldMAProblem{Tprob, AutoDiff, Tu0, Tp, Tl, Tplot, Trecord}, x, p) where {Tprob, Tu0, Tp, Tl <: Union{Lens, Nothing}, Tplot, Trecord} = ForwardDiff.jacobian(z -> foldpb.prob(z, p), x)

jacobian(foldpb::FoldMAProblem{Tprob, FiniteDifferences, Tu0, Tp, Tl, Tplot, Trecord}, x, p) where {Tprob, Tu0, Tp, Tl <: Union{Lens, Nothing}, Tplot, Trecord} = finite_differences( z -> foldpb.prob(z, p), x; δ = 1e-8)

jacobian(foldpb::FoldMAProblem{Tprob, FiniteDifferencesMF, Tu0, Tp, Tl, Tplot, Trecord}, x, p) where {Tprob, Tu0, Tp, Tl <: Union{Lens, Nothing}, Tplot, Trecord} = dx -> (foldpb.prob(x .+ 1e-8 .* dx, p) .- foldpb.prob(x .- 1e-8 .* dx, p)) / (2e-8)
###################################################################################################
"""
$(SIGNATURES)

This function turns an initial guess for a Fold point into a solution to the Fold problem based on a Minimally Augmented formulation. The arguments are as follows
- `prob::AbstractBifurcationFunction`
- `foldpointguess` initial guess (x_0, p_0) for the Fold point. It should be a `BorderedArray` as returned by the function `foldpoint`
- `par` parameters used for the vector field
- `eigenvec` guess for the right null vector
- `eigenvec_ad` guess for the left null vector
- `options::NewtonPar` options for the Newton-Krylov algorithm, see [`NewtonPar`](@ref).

# Optional arguments:
- `normN = norm`
- `bdlinsolver` bordered linear solver for the constraint equation
- `kwargs` keywords arguments to be passed to the regular Newton-Krylov solver

# Simplified call
Simplified call to refine an initial guess for a Fold point. More precisely, the call is as follows

    newtonFold(br::AbstractBranchResult, ind_fold::Int; options = br.contparams.newton_options, kwargs...)

The parameters / options are as usual except that you have to pass the branch `br` from the result of a call to `continuation` with detection of bifurcations enabled and `index` is the index of bifurcation point in `br` you want to refine. You can pass newton parameters different from the ones stored in `br` by using the argument `options`.

!!! tip "Jacobian transpose"
    The adjoint of the jacobian `J` is computed internally when `Jᵗ = nothing` by using `transpose(J)` which works fine when `J` is an `AbstractArray`. In this case, do not pass the jacobian adjoint like `Jᵗ = (x, p) -> transpose(d_xF(x, p))` otherwise the jacobian will be computed twice!

!!! tip "ODE problems"
    For ODE problems, it is more efficient to pass the Bordered Linear Solver using the option `bdlinsolver = MatrixBLS()`
"""
function newton_fold(prob::AbstractBifurcationProblem,
                foldpointguess, par,
                eigenvec, eigenvec_ad,
                options::NewtonPar;
                normN = norm,
                bdlinsolver::AbstractBorderedLinearSolver = MatrixBLS(),
                usehessian = true,
                kwargs...)

    𝐅 = FoldProblemMinimallyAugmented(
        prob,
        _copy(eigenvec),
        _copy(eigenvec_ad),
        options.linsolver,
        # do not change linear solver if the user provides it
        @set bdlinsolver.solver = (isnothing(bdlinsolver.solver) ? options.linsolver : bdlinsolver.solver);
        usehessian = usehessian)

    prob_f = FoldMAProblem(𝐅, nothing, foldpointguess, par, nothing, prob.plotSolution, prob.recordFromSolution)

    # options for the Newton Solver
    opt_fold = @set options.linsolver = FoldLinearSolverMinAug()

    # solve the Fold equations
    return newton(prob_f, opt_fold; normN = normN, kwargs...)
end

function newton_fold(br::AbstractBranchResult, ind_fold::Int;
                prob = br.prob,
                normN = norm,
                options = br.contparams.newton_options,
                nev = br.contparams.nev,
                start_with_eigen = false,
                bdlinsolver::AbstractBorderedLinearSolver = MatrixBLS(),
                kwargs...)
    foldpointguess = foldpoint(br, ind_fold)
    bifpt = br.specialpoint[ind_fold]
    eigenvec = bifpt.τ.u; rmul!(eigenvec, 1 / normN(eigenvec))
    eigenvec_ad = _copy(eigenvec)

    if start_with_eigen
        λ = zero(getvectoreltype(br))
        p = bifpt.param
        parbif = setparam(br, p)

        # jacobian at bifurcation point
        L = jacobian(prob, bifpt.x, parbif)

        # computation of zero eigenvector
        ζstar, = get_adjoint_basis(L, λ, br.contparams.newton_options.eigsolver; nev = nev, verbose = false)
        eigenvec .= real.(ζstar)

        # computation of adjoint eigenvector
        _Jt = ~has_adjoint(prob) ? adjoint(L) : jad(prob, bifpt.x, parbif)
        ζstar, = get_adjoint_basis(_Jt, λ, br.contparams.newton_options.eigsolver; nev = nev, verbose = false)
        eigenvec_ad .= real.(ζstar)
        rmul!(eigenvec_ad, 1 / normN(eigenvec_ad))
    end

    # solve the Fold equations
    return newton_fold(prob,
                        foldpointguess,
                        getparams(br),
                        eigenvec,
                        eigenvec_ad,
                        options; 
                        normN = normN,
                        bdlinsolver = bdlinsolver,
                        kwargs...)
end

"""
$(SIGNATURES)

Codim 2 continuation of Fold points. This function turns an initial guess for a Fold point into a curve of Fold points based on a Minimally Augmented formulation. The arguments are as follows
- `prob::AbstractBifurcationFunction`
- `foldpointguess` initial guess (x_0, p1_0) for the Fold point. It should be a `BorderedArray` as returned by the function `foldpoint`
- `par` set of parameters
- `lens1` parameter axis for parameter 1
- `lens2` parameter axis for parameter 2
- `eigenvec` guess for the right null vector
- `eigenvec_ad` guess for the left null vector
- `options_cont` arguments to be passed to the regular [`continuation`](@ref)

# Optional arguments:
- `jacobian_ma::Symbol = :autodiff`, how the linear system of the Fold problem is solved. Can be `:autodiff, :finiteDifferencesMF, :finiteDifferences, :minaug`
- `bdlinsolver` bordered linear solver for the constraint equation with top-left block J. Required in the linear solver for the Minimally Augmented Fold functional. This option can be used to pass a dedicated linear solver for example with specific preconditioner.
- `bdlinsolver_adjoint` bordered linear solver for the constraint equation with top-left block J^*. Required in the linear solver for the Minimally Augmented Fold functional. This option can be used to pass a dedicated linear solver for example with specific preconditioner.
- `update_minaug_every_step` update vectors `a, b` in Minimally Formulation every `update_minaug_every_step` steps
- `compute_eigen_elements = false` whether to compute eigenelements. If `options_cont.detect_event>0`, it allows the detection of ZH points.
- `kwargs` keywords arguments to be passed to the regular [`continuation`](@ref)

# Simplified call

    continuation_fold(br::AbstractBranchResult, ind_fold::Int64, lens2::Lens, options_cont::ContinuationPar ; kwargs...)

where the parameters are as above except that you have to pass the branch `br` from the result of a call to `continuation` with detection of bifurcations enabled and `index` is the index of Fold point in `br` that you want to continue.

!!! tip "Jacobian transpose"
    The adjoint of the jacobian `J` is computed internally when `Jᵗ = nothing` by using `transpose(J)` which works fine when `J` is an `AbstractArray`. In this case, do not pass the jacobian adjoint like `Jᵗ = (x, p) -> transpose(d_xF(x, p))` otherwise the jacobian would be computed twice!

!!! tip "ODE problems"
    For ODE problems, it is more efficient to use the Matrix based Bordered Linear Solver passing the option `bdlinsolver = MatrixBLS()`. This is the default setting.

!!! tip "Detection of Bogdanov-Takens and Cusp bifurcations"
    In order to trigger the detection, pass `detect_event = 1 or 2` in `options_cont`.
"""
function continuation_fold(prob, alg::AbstractContinuationAlgorithm,
                foldpointguess::BorderedArray{vectype, 𝒯}, par,
                lens1::Lens, lens2::Lens,
                eigenvec, eigenvec_ad,
                options_cont::ContinuationPar ;
                update_minaug_every_step = 0,
                normC = norm,

                bdlinsolver::AbstractBorderedLinearSolver = MatrixBLS(),
                bdlinsolver_adjoint::AbstractBorderedLinearSolver = bdlinsolver,

                jacobian_ma::Symbol = :autodiff,
                compute_eigen_elements = false,
                usehessian = true,
                kind = FoldCont(),
                record_from_solution = nothing,
                kwargs...) where {𝒯, vectype}
    @assert lens1 != lens2 "Please choose 2 different parameters. You only passed $lens1"
    @assert lens1 == getlens(prob)

    # options for the Newton Solver inherited from the ones the user provided
    options_newton = options_cont.newton_options

    𝐅 = FoldProblemMinimallyAugmented(
            prob,
            _copy(eigenvec),
            _copy(eigenvec_ad),
            options_newton.linsolver,
            # do not change linear solver if user provides it
            @set bdlinsolver.solver = (isnothing(bdlinsolver.solver) ? options_newton.linsolver : bdlinsolver.solver);
            linbdsolve_adjoint = bdlinsolver_adjoint,
            usehessian = usehessian)

    # Jacobian for the Fold problem
    if jacobian_ma == :autodiff
        foldpointguess = vcat(foldpointguess.u, foldpointguess.p)
        prob_f = FoldMAProblem(𝐅, AutoDiff(), foldpointguess, par, lens2, prob.plotSolution, prob.recordFromSolution)
        opt_fold_cont = @set options_cont.newton_options.linsolver = DefaultLS()
    elseif jacobian_ma == :finiteDifferencesMF
        foldpointguess = vcat(foldpointguess.u, foldpointguess.p)
        prob_f = FoldMAProblem(𝐅, FiniteDifferencesMF(), foldpointguess, par, lens2, prob.plotSolution, prob.recordFromSolution)
        opt_fold_cont = @set options_cont.newton_options.linsolver = options_cont.newton_options.linsolver
    elseif jacobian_ma == :finiteDifferences
        foldpointguess = vcat(foldpointguess.u, foldpointguess.p)
        prob_f = FoldMAProblem(𝐅, FiniteDifferences(), foldpointguess, par, lens2, prob.plotSolution, prob.recordFromSolution)
        opt_fold_cont = @set options_cont.newton_options.linsolver = options_cont.newton_options.linsolver
    else
        prob_f = FoldMAProblem(𝐅, nothing, foldpointguess, par, lens2, prob.plotSolution, prob.recordFromSolution)
        opt_fold_cont = @set options_cont.newton_options.linsolver = FoldLinearSolverMinAug()
    end

    # this function allows to tackle the case where the two parameters have the same name
    lenses = get_lens_symbol(lens1, lens2)

    # global variables to save call back
    𝐅.BT = one(𝒯)
    𝐅.CP = one(𝒯)
    𝐅.ZH = 1

    # this function is used as a Finalizer
    # it is called to update the Minimally Augmented problem
    # by updating the vectors a, b
    function update_minaug_fold(z, tau, step, contResult; kUP...)
        # user-passed finalizer
        finaliseUser = get(kwargs, :finalise_solution, nothing)

        # we first check that the continuation step was successful
        # if not, we do not update the problem with bad information!
        success = get(kUP, :state, nothing).converged
        if (~mod_counter(step, update_minaug_every_step) || success == false)
            return isnothing(finaliseUser) ? true : finaliseUser(z, tau, step, contResult; prob = 𝐅, kUP...)
        end

        @debug "[Fold] Update vectors a and b"

        x = getvec(z.u) # fold point
        p1 = getp(z.u)  # first parameter
        p2 = z.p        # second parameter
        newpar = set(par, lens1, p1)
        newpar = set(newpar, lens2, p2)

        a = 𝐅.a
        b = 𝐅.b

        # expression of the jacobian
        J_at_xp = jacobian(𝐅.prob_vf, x, newpar)

        # compute new b, close to right null vector
        newb, _, cv, it = 𝐅.linbdsolver(J_at_xp, a, b, zero(𝒯), 𝐅.zero, one(𝒯))
        ~cv && @debug "[FOLD Fin] Bordered linear solver for J did not converge. it = $(it). This is to update 𝐅.b"

        # compute new a, close to left null vector
        if is_symmetric(𝐅)
            JAd_at_xp = J_at_xp
        else
            JAd_at_xp = has_adjoint(𝐅) ? jad(𝐅.prob_vf, x, newpar) : transpose(J_at_xp)
        end
        newa, _, cv, it = 𝐅.linbdsolver(JAd_at_xp, b, a, zero(𝒯), 𝐅.zero, one(𝒯))
        ~cv && @debug "[FOLD Fin] Bordered linear solver for J' did not converge. it = $(it). This is to update 𝐅.a"

        copyto!(𝐅.a, newa); rmul!(𝐅.a, 1 / normC(newa))

        # do not normalize with dot(newb, 𝐅.a), it prevents from BT detection
        copyto!(𝐅.b, newb); rmul!(𝐅.b, 1 / normC(newb))

        # call the user-passed finalizer
        finaliseUser = get(kwargs, :finalise_solution, nothing)
        if isnothing(finaliseUser) == false
            return finaliseUser(z, tau, step, contResult; prob = 𝐅, kUP...)
        end
        return true
    end

    function test_bt_cp(iter, state)
        z = getx(state)
        x = getvec(z)    # fold point
        p1 = getp(z)     # first parameter
        p2 = getp(state) # second parameter
        newpar = set(par, lens1, p1)
        newpar = set(newpar, lens2, p2)

        probfold = iter.prob.prob

        a = probfold.a
        b = probfold.b

        # expression of the jacobian
        J_at_xp = jacobian(probfold.prob_vf, x, newpar)

        # compute new b
        ζ, _, cv, it = probfold.linbdsolver(J_at_xp, a, b, zero(𝒯), probfold.zero, one(𝒯))
        ~cv && @debug "[FOLD test] Bordered linear solver for J did not converge. it = $(it). This is to update ζ"
        rmul!(ζ, 1 / normC(ζ))

        # compute new a
        JAd_at_xp = has_adjoint(probfold) ? jad(probfold, x, newpar) : transpose(J_at_xp)
        ζstar, _, cv, it = probfold.linbdsolver(JAd_at_xp, b, a, zero(𝒯), probfold.zero, one(𝒯))
        ~cv && @debug "[FOLD test] Bordered linear solver for J' did not converge. it = $(it). This is to update ζstar"
        rmul!(ζstar, 1 / normC(ζstar))

        probfold.BT = dot(ζstar, ζ)
        probfold.CP = getp(state.τ)

        return probfold.BT, probfold.CP
    end

    function test_zh(iter, state)
        if isnothing(state.eigvals)
            iter.prob.prob.ZH = 1
        else
            ϵ = iter.contparams.tol_stability
            ρ = minimum(abs ∘ real, state.eigvals)
            iter.prob.prob.ZH = mapreduce(x -> ((real(x) > ρ) & (imag(x) > ϵ)), +, state.eigvals)
        end
        return iter.prob.prob.ZH
    end

    # the following allows to append information specific to the codim 2 continuation to the user data
    _printsol = record_from_solution
    _printsol2 = isnothing(_printsol) ?
        (u, p; kw...) -> (; zip(lenses, (getp(u), p))..., BT = 𝐅.BT, CP = 𝐅.CP, ZH = 𝐅.ZH, namedprintsol(BifurcationKit.record_from_solution(prob)(getvec(u), p; kw...))...) :
        (u, p; kw...) -> (; namedprintsol(_printsol(getvec(u), p; kw...))..., zip(lenses, (getp(u, 𝐅), p))..., BT = 𝐅.BT, CP = 𝐅.CP, ZH = 𝐅.ZH,)

    prob_f = re_make(prob_f, record_from_solution = _printsol2)

    # eigen solver
    eigsolver = FoldEig(getsolver(opt_fold_cont.newton_options.eigsolver), prob_f)

    # define event for detecting bifurcations. Coupled with user passed events
    event_user = get(kwargs, :event, nothing)
    if isnothing(event_user)
        event = PairOfEvents(
            ContinuousEvent(2, test_bt_cp, compute_eigen_elements, ("bt", "cusp"), 0),
            DiscreteEvent(1, test_zh, false, ("zh",)))
    else
        event = SetOfEvents(
            ContinuousEvent(2, test_bt_cp, compute_eigen_elements, ("bt", "cusp"), 0),
            DiscreteEvent(1, test_zh, false, ("zh",)),
            event_user
            )
    end

    # solve the Fold equations
    br = continuation(
        prob_f, alg,
        (@set opt_fold_cont.newton_options.eigsolver = eigsolver);
        linear_algo = BorderingBLS(solver = opt_fold_cont.newton_options.linsolver, check_precision = false),
        kwargs...,
        kind = kind,
        normC = normC,
        finalise_solution = update_minaug_every_step == 0 ? get(kwargs, :finalise_solution, finalise_default) : update_minaug_fold,
        event = event
        )
    @assert ~isnothing(br) "Empty branch!"
    return correct_bifurcation(br)
end

function continuation_fold(prob,
                br::AbstractBranchResult, ind_fold::Int,
                lens2::Lens,
                options_cont::ContinuationPar = br.contparams ;
                alg = br.alg,
                normC = norm,
                nev = br.contparams.nev,
                start_with_eigen = false,
                bdlinsolver::AbstractBorderedLinearSolver = MatrixBLS(),
                bdlinsolver_adjoint = bdlinsolver,
                kwargs...)
    foldpointguess = foldpoint(br, ind_fold)
    bifpt = br.specialpoint[ind_fold]
    ζ = bifpt.τ.u; rmul!(ζ, 1 / norm(ζ))
    ζad = _copy(ζ)

    p = bifpt.param
    parbif = setparam(br, p)

    if start_with_eigen
        # jacobian at bifurcation point
        L = jacobian(prob, bifpt.x, parbif)

        # computation of zero eigenvector
        if bifpt.ind_ev > 0 && haseigenvector(br)
            ζ .= real.( geteigenvector(br.contparams.newton_options.eigsolver, br.eig[bifpt.idx].eigenvecs, bifpt.ind_ev))
            rmul!(ζ, 1/normC(ζ))
        else
            @assert 1==0 "This is an issue. Please open an issue on the website of BifurcationKit."
        end

        # jacobian adjoint at bifurcation point
        L★ = has_adjoint(prob) ? jad(prob, bifpt.x, parbif) : transpose(L)

        # computation of zero adjoint eigenvector
        ζ★, λ★ = get_adjoint_basis(L★, 0, br.contparams.newton_options.eigsolver; nev = nev, verbose = options_cont.newton_options.verbose)
        ζad = real.(ζ★)
        rmul!(ζad, 1 / dot(ζ, ζ★))
    end

    return continuation_fold(prob, alg,
            foldpointguess, parbif,
            getlens(br), lens2,
            ζ, ζad,
            options_cont ;
            normC,
            bdlinsolver,
            bdlinsolver_adjoint,
            kwargs...)
end

# structure to compute eigen-elements along branch of Fold points
struct FoldEig{S, P} <: AbstractCodim2EigenSolver
    eigsolver::S
    prob::P
end
FoldEig(solver) = FoldEig(solver, nothing)

function (eig::FoldEig)(Jma, nev; kwargs...)
    # il ne faut pas mettre a jour les deux params?
    n = min(nev, length(getvec(Jma.x)))
    J = jacobian(Jma.prob.prob_vf, getvec(Jma.x), set(Jma.params, getlens(Jma.prob), getp(Jma.x)))
    eigenelts = eig.eigsolver(J, n; kwargs...)
    return eigenelts
end

@views function (eig::FoldEig)(Jma::AbstractMatrix, nev; kwargs...)
    eigenelts = eig.eigsolver(Jma[1:end-1,1:end-1], nev; kwargs...)
    return eigenelts
end

geteigenvector(eig::FoldEig, vectors, i::Int) = geteigenvector(eig.eigsolver, vectors, i)

get_bifurcation_type(it::ContIterable, state, status::Symbol, interval::Tuple{T, T}, eig::FoldEig) where T = get_bifurcation_type(it, state, status, interval, eig.eigsolver)
