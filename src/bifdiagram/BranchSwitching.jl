"""
$(SIGNATURES)

[Internal] This function is not meant to be called directly.

This function is the analog of [`continuation`](@ref) when the first two points on the branch are passed (instead of a single one). Hence `x0` is the first point on the branch (with palc `s=0`) with parameter `par0` and `x1` is the second point with parameter `set(par0, lens, p1)`.
"""
function continuation(prob::AbstractBifurcationProblem,
                    x0::Tv, par0,     # first point on the branch
                    x1::Tv, p1::Real, # second point on the branch
                    alg, lens::Lens,
                    contParams::ContinuationPar;
                    bothside::Bool = false,
                    kwargs...) where Tv
    # update alg linear solver with contParams.newton_options.linsolver
    alg = update(alg, contParams, nothing)
    # check the sign of ds
    dsfactor = sign(p1 - get(par0, lens))
    # create an iterable
    _contParams = @set contParams.ds = abs(contParams.ds) * dsfactor
    prob2 = re_make(prob; lens = lens, params = par0)
    if ~bothside
        it = ContIterable(prob2, alg, _contParams; kwargs...)
        return continuation(it, x0, get(par0, lens), x1, p1)
    else
        itfw = ContIterable(prob2, alg, _contParams; kwargs...)
        itbw = deepcopy(itfw)
        resfw = continuation(itfw, x0, get(par0, lens), x1, p1)
        resbw = continuation(itbw, x1, p1, x0, get(par0, lens))
        return _merge(resfw, resbw)
    end
end

function continuation(it::ContIterable, x0, p0::Real, x1, p1::Real)
    # we compute the cache for the continuation, i.e. state::ContState
    # In this call, we also compute the initial point on the branch (and its stability) and the initial tangent
    state, _ = iterate_from_two_points(it, x0, p0, x1, p1)

    # variable to hold the result from continuation, i.e. a branch
    contRes = ContResult(it, state)

    # perform the continuation
    return continuation!(it, state, contRes)
end

"""
$(SIGNATURES)

Automatic branch switching at branch points based on a computation of the normal form. More information is provided in [Branch switching](@ref Branch-switching-page). An example of use is provided in [2d generalized Bratu–Gelfand problem](@ref).

# Arguments
- `br` branch result from a call to [`continuation`](@ref)
- `ind_bif` index of the bifurcation point in `br` from which you want to branch from
- `options_cont` options for the call to [`continuation`](@ref)

# Optional arguments
- `alg = br.alg` continuation algorithm to be used, default value: `br.alg`
- `δp` used to specify a specific value for the parameter on the bifurcated branch which is otherwise determined by `options_cont.ds`. This allows to use a step larger than `options_cont.dsmax`.
- `ampfactor = 1` factor to alter the amplitude of the bifurcated solution. Useful to magnify the bifurcated solution when the bifurcated branch is very steep.
- `nev` number of eigenvalues to be computed to get the right eigenvector
- `usedeflation = false` whether to use nonlinear deflation (see [Deflated problems](@ref Deflated-problems)) to help finding the guess on the bifurcated
- `verbosedeflation` print deflated newton iterations
- `max_iter_deflation` number of newton steps in deflated newton
- `perturb = identity` which perturbation function to use during deflated newton
- `Teigvec = _getvectortype(br)` type of the eigenvector. Useful when `br` was loaded from a file and this information was lost
- `scaleζ = norm` pass a norm to normalize vectors during normal form computation
- `plot_solution` change plot solution method in the problem `br.prob`
- `kwargs` optional arguments to be passed to [`continuation`](@ref), the regular `continuation` one and to [`get_normal_form`](@ref).

!!! tip "Advanced use"
    In the case of a very large model and use of special hardware (GPU, cluster), we suggest to discouple the computation of the reduced equation, the predictor and the bifurcated branches. Have a look at `methods(BifurcationKit.multicontinuation)` to see how to call these versions. These methods has been tested on GPU with very high memory pressure.
"""
function continuation(br::AbstractResult{EquilibriumCont, Tprob}, ind_bif::Int, options_cont::ContinuationPar = br.contparams ;
        alg = br.alg,
        δp = nothing, ampfactor::Real = 1,
        nev = options_cont.nev,
        usedeflation::Bool = false,
        verbosedeflation::Bool = false,
        max_iter_deflation::Int = min(50, 15options_cont.newton_options.max_iterations),
        perturb = identity,
        plot_solution = plot_solution(br.prob),
        Teigvec = _getvectortype(br),
        scaleζ = norm,
        tol_fold = 1e-3,
        kwargs...) where Tprob
    # The usual branch switching algorithm is described in Keller. Numerical solution of bifurcation and nonlinear eigenvalue problems. We do not use this algorithm but instead compute the Lyapunov-Schmidt decomposition and solve the polynomial equation.

    verbose = get(kwargs, :verbosity, 0) > 0 ? true : false
    verbose && println("──▶ Considering bifurcation point:")
    verbose && _show(stdout, br.specialpoint[ind_bif], ind_bif)

    if kernel_dimension(br, ind_bif) > 1
        return multicontinuation(br, ind_bif, options_cont; δp = δp, ampfactor = ampfactor, nev = nev, scaleζ = scaleζ, verbosedeflation = verbosedeflation, max_iter_deflation = max_iter_deflation, perturb = perturb, Teigvec = Teigvec, alg = alg, plot_solution = plot_solution, kwargs...)
    end

    @assert br.specialpoint[ind_bif].type == :bp "This bifurcation type is not handled.\n Branch point from $(br.specialpoint[ind_bif].type)"

    # compute predictor for point on new branch
    ds = isnothing(δp) ? options_cont.ds : δp
    Ty = typeof(ds)

    # compute the normal form of the bifurcation point
    bp = get_normal_form1d(br, ind_bif; nev = nev, verbose = verbose, Teigvec = Teigvec, scaleζ = scaleζ, tol_fold = tol_fold)

    # compute predictor for a point on new branch
    pred = predictor(bp, ds; verbose = verbose, ampfactor = Ty(ampfactor))
    if isnothing(pred); return nothing; end

    verbose && printstyled(color = :green, "\n──▶ Start branch switching. \n──▶ Bifurcation type = ", type(bp), "\n────▶ newp = ", pred.p, ", δp = ", pred.p - br.specialpoint[ind_bif].param, "\n")

    if usedeflation
        verbose && println("\n────▶ Compute point on the current branch with nonlinear deflation...")
        optn = options_cont.newton_options
        bifpt = br.specialpoint[ind_bif]
        # find the bifurcated branch using nonlinear deflation
        solbif = newton(br.prob, convert(Teigvec, pred.x0), pred.x1, setparam(br, pred.p), setproperties(optn; verbose = verbosedeflation); kwargs...)[1]
        copyto!(pred.x1, solbif.u)
    end

    # perform continuation
    branch = continuation(re_make(br.prob, plot_solution = plot_solution),
            bp.x0, bp.params, # first point on the branch
            pred.x1, pred.p,  # second point on the branch
            alg, getlens(br),
            options_cont; kwargs...)
    return Branch(branch, bp)
end

# same but for a Branch
continuation(br::AbstractBranchResult, ind_bif::Int, options_cont::ContinuationPar = br.contparams ; kwargs...) = continuation(get_contresult(br), ind_bif, options_cont ; kwargs...)

"""
$(SIGNATURES)

Automatic branch switching at branch points based on a computation of the normal form. More information is provided in [Branch switching](@ref). An example of use is provided in [2d generalized Bratu–Gelfand problem](@ref).

# Arguments
- `br` branch result from a call to [`continuation`](@ref)
- `ind_bif` index of the bifurcation point in `br` from which you want to branch from
- `options_cont` options for the call to [`continuation`](@ref)

# Optional arguments
- `alg = br.alg` continuation algorithm to be used, default value: `br.alg`
- `δp` used to specify a particular guess for the parameter on the bifurcated branch which is otherwise determined by `options_cont.ds`. This allows to use a step larger than `options_cont.dsmax`.
- `ampfactor = 1` factor which alters the amplitude of the bifurcated solution. Useful to magnify the bifurcated solution when the bifurcated branch is very steep.
- `nev` number of eigenvalues to be computed to get the right eigenvector
- `verbosedeflation = true` whether to display the nonlinear deflation iterations (see [Deflated problems](@ref Deflated-problems)) to help finding the guess on the bifurcated branch
- `scaleζ` norm used to normalize eigenbasis when computing the reduced equation
- `Teigvec` type of the eigenvector. Useful when `br` was loaded from a file and this information was lost
- `ζs` basis of the kernel
- `perturb_guess = identity` perturb the guess from the predictor just before the deflated-newton correction
- `kwargs` optional arguments to be passed to [`continuation`](@ref), the regular `continuation` one.

!!! tip "Advanced use"
    In the case of a very large model and use of special hardware (GPU, cluster), we suggest to discouple the computation of the reduced equation, the predictor and the bifurcated branches. Have a look at `methods(BifurcationKit.multicontinuation)` to see how to call these versions. These methods has been tested on GPU with very high memory pressure.
"""
function multicontinuation(br::AbstractBranchResult, ind_bif::Int, options_cont::ContinuationPar = br.contparams;
        δp = nothing,
        ampfactor::Real = getvectoreltype(br)(1),
        nev::Int = options_cont.nev,
        Teigvec = _getvectortype(br),
        ζs = nothing,
        verbosedeflation::Bool = false,
        scaleζ = norm,
        perturb_guess = identity,
        plot_solution = plot_solution(br.prob),
        kwargs...)

    verbose = get(kwargs, :verbosity, 0) > 0 ? true : false

    bpnf = get_normal_form(br, ind_bif; nev = nev, verbose = verbose, Teigvec = Teigvec, ζs = ζs, scaleζ = scaleζ)

    return multicontinuation(br, bpnf, options_cont; Teigvec = Teigvec, δp = δp, ampfactor = ampfactor, verbosedeflation = verbosedeflation, plot_solution = plot_solution, kwargs...)
end

# for AbstractBifurcationPoint (like Hopf, BT, ...), it must return nothing
multicontinuation(br::AbstractBranchResult, bpnf::AbstractBifurcationPoint, options_cont::ContinuationPar; kwargs...) = nothing

# general function for branching from Nd bifurcation points
function multicontinuation(br::AbstractBranchResult,
                        bpnf::NdBranchPoint,
                        options_cont::ContinuationPar = br.contparams;
                        δp = nothing,
                        ampfactor = getvectoreltype(br)(1),
                        perturb = identity,
                        plot_solution = plot_solution(br.prob),
                        kwargs...)

    verbose = get(kwargs, :verbosity, 0) > 0 ? true & get(kwargs, :verbosedeflation, true) : false

    # compute predictor for point on new branch
    ds = abs(isnothing(δp) ? options_cont.ds : δp)

    # get prediction from solving the reduced equation
    rootsNFm, rootsNFp = predictor(bpnf, ds;  verbose = verbose, perturb = perturb, ampfactor = ampfactor)

    return multicontinuation(br, bpnf, (before = rootsNFm, after = rootsNFp), options_cont; δp = δp, plot_solution = plot_solution, kwargs...)
end

"""
$(SIGNATURES)

Function to transform predictors `solfromRE` in the normal form coordinates of `bpnf` into solutions. Note that `solfromRE = (before = Vector{vectype}, after = Vector{vectype})`.
"""
function get_first_points_on_branch(br::AbstractBranchResult,
        bpnf::NdBranchPoint, solfromRE,
        options_cont::ContinuationPar = br.contparams ;
        δp = nothing,
        Teigvec = _getvectortype(br),
        usedeflation = true,
        verbosedeflation = false,
        max_iter_deflation = min(50, 15options_cont.newton_options.max_iterations),
        lsdefop = DeflatedProblemCustomLS(),
        perturb_guess = identity,
        kwargs...)
    # compute predictor for point on new branch
    ds = isnothing(δp) ? options_cont.ds : δp |> abs
    dscont = abs(options_cont.ds)

    rootsNFm = solfromRE.before
    rootsNFp = solfromRE.after

    # attempting now to convert the guesses from the normal form into true zeros of F
    optn = options_cont.newton_options

    # options for newton
    cbnewton = get(kwargs, :callback_newton, cb_default)
    normn = get(kwargs, :normC, norm)

    printstyled(color = :magenta, "──▶ Looking for solutions after the bifurcation point...\n")
    defOpp = DeflationOperator(2, 1.0, Vector{typeof(bpnf.x0)}(), _copy(bpnf.x0); autodiff = true)
    optnDf = setproperties(optn; max_iterations = max_iter_deflation, verbose = verbosedeflation)

    for (ind, xsol) in pairs(rootsNFp)
        probp = re_make(br.prob; u0 = perturb_guess(bpnf(xsol, ds)),
                                params = setparam(br, bpnf.p + ds))
        if usedeflation
            solbif = newton(probp, defOpp, optnDf, lsdefop; callback = cbnewton, normN = normn)
        else
            solbif = newton(probp, optnDf; callback = cbnewton, normN = normn)
        end
        converged(solbif) && push!(defOpp, solbif.u)
    end

    printstyled(color = :magenta, "──▶ Looking for solutions before the bifurcation point...\n")
    defOpm = DeflationOperator(2, 1.0, Vector{typeof(bpnf.x0)}(), _copy(bpnf.x0); autodiff = true)
    for (ind, xsol) in pairs(rootsNFm)
        probm = re_make(br.prob; u0 = perturb_guess(bpnf(xsol, ds)),
                                params = setparam(br, bpnf.p - ds))
        if usedeflation
            solbif = newton(probm, defOpm, optnDf, lsdefop; callback = cbnewton, normN = normn)
        else
            solbif = newton(probm, optnDf; callback = cbnewton, normN = normn)
        end
        converged(solbif) && push!(defOpm, solbif.u)
    end
    printstyled(color=:magenta, "──▶ we find $(length(defOpp)) (resp. $(length(defOpm))) roots after (resp. before) the bifurcation point.\n")
    return (before = defOpm, after = defOpp, bpm = bpnf.p - ds, bpp = bpnf.p + ds)
end

# In this function, I keep usedeflation although it is not used to simplify the calls
function multicontinuation(br::AbstractBranchResult,
        bpnf::NdBranchPoint, solfromRE,
        options_cont::ContinuationPar = br.contparams ;
        δp = nothing,
        Teigvec = _getvectortype(br),
        verbosedeflation = false,
        max_iter_deflation = min(50, 15options_cont.newton_options.max_iterations),
        lsdefop = DeflatedProblemCustomLS(),
        perturb_guess = identity,
        kwargs...)

    defOpm, defOpp, _, _ = get_first_points_on_branch(br, bpnf, solfromRE, options_cont; δp = δp, verbosedeflation = verbosedeflation, max_iter_deflation = max_iter_deflation, lsdefop = lsdefop, perturb_guess = perturb_guess, kwargs...)

    multicontinuation(br,
            bpnf, defOpm, defOpp, options_cont;
            δp = δp,
            Teigvec = Teigvec,
            verbosedeflation = verbosedeflation,
            max_iter_deflation = max_iter_deflation,
            lsdefop = lsdefop,
            kwargs...)
end

"""
$(SIGNATURES)

Automatic branch switching at branch points based on a computation of the normal form. More information is provided in [Branch switching](@ref). An example of use is provided in [2d generalized Bratu–Gelfand problem](@ref).

# Arguments
- `br` branch result from a call to [`continuation`](@ref)
- `bpnf` normal form
- `defOpm::DeflationOperator, defOpp::DeflationOperator` to specify converged points on nonn-trivial branches before/after the bifurcation points.

The rest is as the regular `multicontinuation` function.
"""
function multicontinuation(br::AbstractBranchResult,
        bpnf::NdBranchPoint,
        defOpm::DeflationOperator,
        defOpp::DeflationOperator,
        options_cont::ContinuationPar = br.contparams ;
        alg = br.alg,
        δp = nothing,
        Teigvec = _getvectortype(br),
        verbosedeflation = false,
        max_iter_deflation = min(50, 15options_cont.newton_options.max_iterations),
        lsdefop = DeflatedProblemCustomLS(),
        plot_solution = plot_solution(br.prob),
        kwargs...)

    ds = isnothing(δp) ? options_cont.ds : δp |> abs
    dscont = abs(options_cont.ds)
    par = bpnf.params
    prob = re_make(br.prob; plot_solution = plot_solution)

    # compute the different branches
    function _continue(_sol, _dp, _ds)
        # needed to reset the tangent algorithm in case fields are used
        println("━"^50)
        continuation(prob,
            bpnf.x0, par,       # first point on the branch
            _sol, bpnf.p + _dp, # second point on the branch
            empty(alg), getlens(br),
            (@set options_cont.ds = _ds); kwargs...)
    end

    branches = Branch[]
    for id in 2:length(defOpm)
        br = _continue(defOpm[id], -ds, -dscont); push!(branches, Branch(br, bpnf))
        # br, = _continue(defOpm[id], -ds, dscont); push!(branches, Branch(br, bpnf))
    end

    for id in 2:length(defOpp)
        br = _continue(defOpp[id], ds, dscont); push!(branches, Branch(br, bpnf))
        # br, = _continue(defOpp[id], ds, -dscont); push!(branches, Branch(br, bpnf))
    end

    return branches
end

# same but for a Branch
multicontinuation(br::Branch, ind_bif::Int, options_cont::ContinuationPar = br.contparams; kwargs...) = multicontinuation(get_contresult(br), ind_bif, options_cont ; kwargs...)
