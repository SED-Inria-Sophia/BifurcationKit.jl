@inline has_adjoint_MF(::WrapPOColl) = false
@inline has_hessian(::WrapPOColl) = false

d2F(pbwrap::WrapPOColl, x, p, dx1, dx2) = d2PO(z -> pbwrap.prob(z, p), x, dx1, dx2)

function Base.transpose(J::FloquetWrapper{ <: PeriodicOrbitOCollProblem})
    @set J.jacpb = transpose(J.jacpb)
end

function Base.adjoint(J::FloquetWrapper{ <: PeriodicOrbitOCollProblem})
    @set J.jacpb = adjoint(J.jacpb)
end

function jacobian_period_doubling(pbwrap::WrapPOColl, x, par)
    N, m, Ntst = size(pbwrap.prob)
    Jac = jacobian(pbwrap, x, par)
    # put the PD boundary condition
    J = copy(_get_matrix(Jac))
    J[end-N:end-1, 1:N] .= I(N)
    @set Jac.jacpb = J[1:end-1, 1:end-1]
end

function jacobian_neimark_sacker(pbwrap::WrapPOColl, x, par, ω)
    N, m, Ntst = size(pbwrap.prob)
    Jac = jacobian(pbwrap, x, par)
    # put the NS boundary condition
    J = Complex.(_get_matrix(Jac))
    J[end-N:end-1, end-N:end-1] .= UniformScaling(cis(ω))(N)
    Jns = @set Jac.jacpb = J[1:end-1, 1:end-1]
end

function continuation(br::AbstractResult{Tkind, Tprob},
                    ind_bif::Int64,
                    lens2::AllOpticTypes,
                    options_cont::ContinuationPar = br.contparams ;
                    detect_codim2_bifurcation::Int = 0,
                    update_minaug_every_step = 1,
                    kwargs...) where {Tkind <: PeriodicOrbitCont, Tprob <: WrapPOColl}
    biftype = br.specialpoint[ind_bif].type

    # options to detect codim2 bifurcations
    compute_eigen_elements = options_cont.detect_bifurcation > 0
    _options_cont = detect_codim2_parameters(detect_codim2_bifurcation, options_cont; update_minaug_every_step, kwargs...)

    if biftype in (:bp, :fold)
        return continuation_coll_fold(br,
                                    ind_bif,
                                    lens2,
                                    _options_cont; 
                                    compute_eigen_elements,
                                    update_minaug_every_step,
                                    kwargs... )
    elseif biftype == :pd
        return continuation_coll_pd(br,
                                    ind_bif,
                                    lens2,
                                    _options_cont; compute_eigen_elements,
                                    update_minaug_every_step,
                                    kwargs... )
    elseif biftype == :ns
        return continuation_coll_ns(br,
                                    ind_bif,
                                    lens2,
                                    _options_cont; compute_eigen_elements,
                                    update_minaug_every_step,
                                    kwargs... )
    else
        throw("We continue only Fold / PD / NS points of periodic orbits. Please report this error on the website.")
    end
    nothing
end

function foldpoint(br::AbstractResult{Tkind, Tprob}, index::Int) where {Tkind <: PeriodicOrbitCont, Tprob <: WrapPOColl}
    bptype = br.specialpoint[index].type
    @assert bptype == :bp || bptype == :nd || bptype == :fold "This should be a Fold / BP point"
    specialpoint = br.specialpoint[index]
    if specialpoint.x isa POSolutionAndState
        # the solution is mesh adapted, we need to restore the mesh.
        pbwrap = deepcopy(br.prob)
        update_mesh!(pbwrap.prob, specialpoint.x._mesh )
        specialpoint = @set specialpoint.x = specialpoint.x.sol
    end
    return BorderedArray(_copy(specialpoint.x), specialpoint.param)
end

function pd_point(br::AbstractResult{Tkind, Tprob}, index::Int) where {Tkind <: PeriodicOrbitCont, Tprob <: WrapPOColl}
    bptype = br.specialpoint[index].type
    @assert bptype == :pd "This should be a PD point"
    specialpoint = br.specialpoint[index]
    if specialpoint.x isa POSolutionAndState
        # the solution is mesh adapted, we need to restore the mesh.
        pbwrap = deepcopy(br.prob)
        update_mesh!(pbwrap.prob, specialpoint.x._mesh )
        specialpoint = @set specialpoint.x = specialpoint.x.sol
    end
    return BorderedArray(_copy(specialpoint.x), specialpoint.param)
end

"""
$(SIGNATURES)

Continuation of curve of fold bifurcations of periodic orbits computed using collocation method.

# Arguments
- `br` branch of periodic orbits computed with a [`PeriodicOrbitTrapProblem`](@ref)
- `ind_bif` index of the fold point
- `lens2::AllOpticTypes` second parameter axis
- `options_cont` parameters to be used by a regular [`continuation`](@ref)
"""
function continuation_coll_fold(br::AbstractResult{Tkind, Tprob},
                    ind_bif::Int64,
                    lens2::AllOpticTypes,
                    options_cont::ContinuationPar = br.contparams ;
                    start_with_eigen = false,
                    bdlinsolver = MatrixBLS(),
                    kwargs...) where {Tkind <: PeriodicOrbitCont, Tprob <: WrapPOColl}
    biftype = br.specialpoint[ind_bif].type
    bifpt = br.specialpoint[ind_bif]
    ϕ = bifpt.x isa POSolutionAndState ? copy(bifpt.x.ϕ) : copy(bifpt.x)

    # if mesh adaptation, we need to extract the solution specifically
    if bifpt.x isa POSolutionAndState
        # the solution is mesh adapted, we need to restore the mesh.
        pbwrap = deepcopy(br.prob)
        update_mesh!(pbwrap.prob, bifpt.x._mesh )
        updatesection!(pbwrap.prob, bifpt.x.ϕ, nothing)
        bifpt = @set bifpt.x = bifpt.x.sol
    end

    # we get the collocation problem
    coll = deepcopy(getprob(br).prob)

    # update section
    # THIS IS A HACK, SHOULD BE SAVED FOR PROPER BRANCHING ETC
    # updatesection!(coll, ϕ, nothing)

    _finsol = modify_po_finalise(FoldMAProblem(FoldProblemMinimallyAugmented(WrapPOColl(coll)), lens2), kwargs, coll.update_section_every_step)

    if get_plot_backend() == BK_Makie()
        plotsol = (ax, x, p; ax1 = nothing, k...) -> br.prob.plotSolution(ax, x.u, p; ax1, k...)
    else
        plotsol = (x, p;k...) -> br.prob.plotSolution(x.u, p; fromcodim2 = true, k...)
    end

    coll_fold = BifurcationProblem((x, p) -> residual(coll, x, p), bifpt, getparams(br), getlens(br);
                J = getprob(br).jacobian,
                d2F = (x, p, dx1, dx2) -> d2PO(z -> residual(coll, z, p), x, dx1, dx2),
                plot_solution = plotsol
                )

    options_foldpo = @set options_cont.newton_options.linsolver = FloquetWrapperLS(options_cont.newton_options.linsolver)

    # perform continuation
    br_fold_po = continuation_fold(coll_fold,
        br, ind_bif, lens2,
        options_foldpo;
        start_with_eigen = start_with_eigen,
        bdlinsolver = FloquetWrapperBLS(bdlinsolver),
        kind = FoldPeriodicOrbitCont(),
        finalise_solution = _finsol,
        kwargs...
        )
    correct_bifurcation(br_fold_po)
end

"""
$(SIGNATURES)

Continuation of curve of period-doubling bifurcations of periodic orbits computed using collocation method.

# Arguments
- `br` branch of periodic orbits computed with a [`PeriodicOrbitTrapProblem`](@ref)
- `ind_bif` index of the PD point
- `lens2::AllOpticTypes` second parameter axis
- `options_cont` parameters to be used by a regular [`continuation`](@ref)
"""
function continuation_coll_pd(br::AbstractResult{Tkind, Tprob},
                    ind_bif::Int64,
                    lens2::AllOpticTypes,
                    options_cont::ContinuationPar = br.contparams ;
                    alg = br.alg,
                    start_with_eigen = false,
                    bdlinsolver = MatrixBLS(),
                    prm = false,
                    kwargs...) where {Tkind <: PeriodicOrbitCont, Tprob <: WrapPOColl}
    bifpt = br.specialpoint[ind_bif]
    biftype = bifpt.type

    @assert biftype == :pd "Please open an issue on BifurcationKit website"

    pdpointguess = pd_point(br, ind_bif)

    # we copy the problem for not mutating the one passed by the user
    coll = deepcopy(br.prob.prob)
    N, m, Ntst = size(coll)

    # get the PD eigenvectors
    par = setparam(br, bifpt.param)
    jac = jacobian(br.prob, pdpointguess.u, par)
    J = _get_matrix(jac)
    nj = size(J, 1)
    J[end, :] .= rand(nj) # must be close to kernel
    J[:, end] .= rand(nj)
    J[end, end] = 0
    # enforce PD boundary condition
    J[end-N:end-1, 1:N] .= I(N)
    rhs = zeros(nj); rhs[end] = 1
    q = J  \ rhs; q = q[1:end-1]; q ./= norm(q) # ≈ ker(J)
    p = J' \ rhs; p = p[1:end-1]; p ./= norm(p)

    # perform continuation
    continuation_pd(br.prob, alg,
        pdpointguess, setparam(br, pdpointguess.p),
        getlens(br), lens2,
        p, q,
        options_cont;
        kwargs...,
        prm,
        # detect_codim2_bifurcation = detect_codim2_bifurcation,
        bdlinsolver = FloquetWrapperBLS(bdlinsolver),
        kind = PDPeriodicOrbitCont(),
        )
end

"""
$(SIGNATURES)

Continuation of curve of Neimark-Sacker bifurcations of periodic orbits computed using collocation method.

# Arguments
- `br` branch of periodic orbits computed with a [`PeriodicOrbitTrapProblem`](@ref)
- `ind_bif` index of the NS point
- `lens2::AllOpticTypes` second parameter axis
- `options_cont` parameters to be used by a regular [`continuation`](@ref)
"""
function continuation_coll_ns(br::AbstractResult{Tkind, Tprob},
                    ind_bif::Int64,
                    lens2::AllOpticTypes,
                    options_cont::ContinuationPar = br.contparams ;
                    alg = br.alg,
                    start_with_eigen = false,
                    bdlinsolver = MatrixBLS(),
                    prm = false,
                    kwargs...) where {Tkind <: PeriodicOrbitCont, Tprob <: WrapPOColl}
    bifpt = br.specialpoint[ind_bif]
    biftype = bifpt.type
    @assert biftype == :ns "We continue only NS points of Periodic orbits for now"
    nspointguess = ns_point(br, ind_bif)

    # we copy the problem for not mutating the one passed by the user
    coll = deepcopy(br.prob.prob)
    N, m, Ntst = size(coll)

    # get the NS eigenvectors
    par = setparam(br, bifpt.param)
    jac = jacobian(br.prob, nspointguess.u, par)
    J = Complex.(copy(_get_matrix(jac)))
    nj = size(J, 1)
    J[end, :] .= rand(nj) # must be close to eigenspace
    J[:, end] .= rand(nj)
    J[end, end] = 0
    # enforce NS boundary condition
    λₙₛ = br.eig[bifpt.idx].eigenvals[bifpt.ind_ev]
    J[end-N:end-1, end-N:end-1] .= UniformScaling(exp(λₙₛ))(N)

    rhs = zeros(nj); rhs[end] = 1
    q = J  \ rhs; q = q[1:end-1]; q ./= norm(q) # ≈ ker(J)
    p = J' \ rhs; p = p[1:end-1]; p ./= norm(p)

    # perform continuation
    continuation_ns(br.prob, alg,
        nspointguess, setparam(br, nspointguess.p[1]),
        getlens(br), lens2,
        p, q,
        options_cont;
        kwargs...,
        prm,
        # detect_codim2_bifurcation = detect_codim2_bifurcation,
        bdlinsolver = FloquetWrapperBLS(bdlinsolver),
        kind = NSPeriodicOrbitCont(),
        )
end
