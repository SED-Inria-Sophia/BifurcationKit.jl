# using Revise, Plots
using Test
using BifurcationKit, SparseArrays, LinearAlgebra, ForwardDiff
const BK = BifurcationKit
const FD = ForwardDiff

function Laplacian1D(N, lx, bc = :none)
    hx = 2lx/N
    Δ = spdiagm(0 => -2ones(N), 1 => ones(N-1), -1 => ones(N-1) )
    Δ[1,end]=1; Δ[end,1]=1
    D = spdiagm(1 => ones(N-1), -1 => -ones(N-1) )
    D[1,end]=-1; D[end,1]=1
    D = D / (2hx)
    Δ = Δ / hx^2
    return Δ, D
end

# add to f the nonlinearity
@views function NL!(f, u, p)
    (; r, μ, ν, c3, c5, γ) = p
    n = div(length(u), 2)
    u1 = u[1:n]
    u2 = u[n+1:2n]

    ua = u1.^2 .+ u2.^2

    f1 = f[1:n]
    f2 = f[n+1:2n]

    f1 .+= @. r * u1 - ν * u2 - ua * (c3 * u1 - μ * u2) - c5 * ua^2 * u1 + γ
    f2 .+= @. r * u2 + ν * u1 - ua * (c3 * u2 + μ * u1) - c5 * ua^2 * u2

    return f
end

function Fcgl!(f, u, p, t = 0)
    mul!(f, p.Δ, u)
    NL!(f, u, p)
end

Fcgl(u, p, t = 0) = Fcgl!(similar(u), u, p)

# remark: I checked this against finite differences
@views function Jcgl(u, p)
    (; r, μ, ν, c3, c5, Δ) = p

    n = div(length(u), 2)
    u1 = u[1:n]
    u2 = u[n+1:2n]

    ua = u1.^2 .+ u2.^2

    f1u = zero(u1)
    f2u = zero(u1)
    f1v = zero(u1)
    f2v = zero(u1)

    @. f1u =  r - 2 * u1 * (c3 * u1 - μ * u2) - c3 * ua - 4 * c5 * ua * u1^2 - c5 * ua^2
    @. f1v = -ν - 2 * u2 * (c3 * u1 - μ * u2)  + μ * ua - 4 * c5 * ua * u1 * u2
    @. f2u =  ν - 2 * u1 * (c3 * u2 + μ * u1)  - μ * ua - 4 * c5 * ua * u1 * u2
    @. f2v =  r - 2 * u2 * (c3 * u2 + μ * u1) - c3 * ua - 4 * c5 * ua * u2 ^2 - c5 * ua^2

    jacdiag = vcat(f1u, f2v)

    Δ + spdiagm(0 => jacdiag, n => f1v, -n => f2u)
end
####################################################################################################
n = 50
l = pi

Δ, D = Laplacian1D(n, l, :Periodic)
par_cgl = (r = 0.0, μ = 0.5, ν = 1.0, c3 = -1.0, c5 = 1.0, Δ = blockdiag(Δ, Δ), Db = blockdiag(D, D), γ = 0.0, δ = 1.0, N = 2n)
sol0 = zeros(par_cgl.N)

# _sol0 = zeros(2n)
# _J0 = Jcgl(_sol0, par_cgl)
# _J1 = FD.jacobian(z->Fcgl(z, par_cgl), _sol0) |> sparse
# @test _J0 ≈ _J1

prob = BifurcationKit.BifurcationProblem(Fcgl, sol0, par_cgl, (@optic _.r); J = Jcgl)

eigls = EigArpack(1.0, :LM)
eigls = DefaultEig()
# eigls = eig_MF_KrylovKit(tol = 1e-8, dim = 60, x₀ = rand(ComplexF64, Nx*Ny), verbose = 1)
opt_newton = NewtonPar(tol = 1e-9, verbose = true, eigsolver = eigls, max_iterations = 20)
out = @time BK.solve(prob, Newton(), opt_newton, normN = norminf)

opts_br = ContinuationPar(dsmin = 0.001, dsmax = 0.15, ds = 0.001, p_max = 2.5, detect_bifurcation = 3, nev = 9, plot_every_step = 50, newton_options = (@set opt_newton.verbose = false), max_steps = 30, n_inversion = 8, max_bisection_steps=20)
br = continuation(prob, PALC(), opts_br, verbosity = 0)

####################################################################################################
# we test the jacobian
# _J0 = BK.jacobian(prob, sol0, par_cgl)
# _J1 = FD.jacobian(z->BK.residual(prob, z, par_cgl), sol0) |> sparse
# @test _J0 == _J1
####################################################################################################
function guessFromHopfO2(branch, ind_hopf, eigsolver, M, z1, z2 = 0.; phase = 0, k = 1.)
    specialpoint = branch.specialpoint[ind_hopf]
    @show specialpoint.ind_ev

    # parameter value at the Hopf point
    p_hopf = specialpoint.param

    # frequency at the Hopf point
    # @show branch.eig[specialpoint.idx].eigenvals[specialpoint.ind_ev:specialpoint.ind_ev+4]
    ωH = imag(branch.eig[specialpoint.idx].eigenvals[specialpoint.ind_ev]) |> abs

    # vec_hopf is the eigenvector for the eigenvalues iω
    vec_hopf1 = geteigenvector(eigsolver, br.eig[specialpoint.idx][2], specialpoint.ind_ev)
    vec_hopf1 ./=  norm(vec_hopf1)

    vec_hopf2 = geteigenvector(eigsolver, br.eig[specialpoint.idx][2], specialpoint.ind_ev - 2)
    vec_hopf2 ./=  norm(vec_hopf2)

     orbitguess = [real.(specialpoint.x .+
                 z1 .* vec_hopf1 .* exp(2pi * complex(0, 1) .* (ii/(M-1) - phase)) .+
                z2 .* vec_hopf2 .* exp(2pi * complex(0, 1) .* (ii/(M-1) - phase))) for ii=0:M-1]

     X = LinRange(-pi, pi, n) |> collect; X = vcat(X, X)
     # orbitguess = [real.(specialpoint.x .+ z1 .* exp.(complex(0, 1) .* (2pi * ii/(M-1) .- k .* X))) for ii=0:M-1]

    return p_hopf, 2pi/ωH, orbitguess, specialpoint.x, vec_hopf1, vec_hopf2
end
####################################################################################################
# we test TWProblem: travelling wave problem
# number of time slices in the periodic orbit
M = 50

# TW ansatz
r_hopf, Th, orbitguess2, hopfpt, eigvec = guessFromHopfO2(br, 2, opt_newton.eigsolver, M, 1. + 0.0im, 1+0.0im; k = 2.) #TW

uold = copy(orbitguess2[1][1:2n])
# plot(uold[1:end-1]; linewidth = 5)

# we create a TW problem
probTW = BK.TWProblem(prob, par_cgl.Db, copy(uold))
BK.residual(probTW, vcat(uold,.1), par_cgl)
show(probTW)

# we test the sparse formulation of the problem jacobian
_sol0 = rand(2n+1)
_J1 = FD.jacobian(z->BK.residual(probTW, z, par_cgl), _sol0) |> sparse
_J0 = probTW(Val(:JacFullSparse), _sol0, par_cgl)
@test _J1 ≈ _J0

# we test the matrix-free formulation of the problem jacobian
_sol0 = rand(2n+1)
_dsol0 = rand(2n+1)
_out1 = FD.derivative(t -> BK.residual(probTW,_sol0 .+ t .* _dsol0, par_cgl), 0)
_out0 = probTW(_sol0, par_cgl, _dsol0)
@test _out0 ≈ _out1

BK.VFtw(probTW, uold, (user=par_cgl, s=Tuple(0.,)))

# we test the ∂
BK.applyD(probTW, rand(2n))

# we test update section
BK.updatesection!(probTW, probTW.u₀)
####################################################################################################
# test newton method, not meant to converge
sol = newton(probTW, vcat(uold, .1), NewtonPar(verbose = false, max_iterations = 5))
@test BK.converged(sol)
BK.is_symmetric(sol.prob)
sol = newton((@set probTW.jacobian = :FullLU), vcat(uold, .1), NewtonPar(verbose = false, max_iterations = 5))
@test BK.converged(sol)
sol = newton((@set probTW.jacobian = :MatrixFree), vcat(uold, .1), NewtonPar(verbose = false, max_iterations = 5, linsolver = GMRESKrylovKit()))
@test BK.converged(sol)
sol = newton((@set probTW.jacobian = :MatrixFreeAD), vcat(uold, .1), NewtonPar(verbose = false, max_iterations = 5, linsolver = GMRESKrylovKit()))
@test BK.converged(sol)
####################################################################################################
# test continuation method with different Generalised eigensolvers
optn = NewtonPar(tol = 1e-8)
opt_cont_br = ContinuationPar(p_min = -1., p_max = 1., newton_options = optn, max_steps = 3, detect_bifurcation = 2)
continuation((@set probTW.jacobian = :FullLU), vcat(uold,.1), PALC(), opt_cont_br; verbosity = 0)

@reset opt_cont_br.newton_options.eigsolver = BK.DefaultGEig(B = diagm(0=>vcat(ones(2n),0)))
continuation((@set probTW.jacobian = :FullLU), vcat(uold,.1), PALC(), opt_cont_br; verbosity = 0)

BK.GEigArpack(nothing, :LR)
@reset opt_cont_br.newton_options.eigsolver = EigArpack(nev = 5, which = :LM, sigma = 0.2, v0 = rand(2n+1))
continuation(probTW, vcat(uold,.1), PALC(), opt_cont_br; verbosity = 0)

@reset opt_cont_br.newton_options.linsolver = GMRESIterativeSolvers(N = 2n+1)
@reset opt_cont_br.newton_options.eigsolver = EigArpack(nev = 4, ncv = 2n+1, tol = 1e-3, v0 = rand(2n+1))
@reset opt_cont_br.detect_bifurcation = 0
continuation((@set probTW.jacobian = :MatrixFreeAD), vcat(uold,.1), PALC(), opt_cont_br; verbosity = 0)
continuation((@set probTW.jacobian = :MatrixFree), vcat(uold,.1), PALC(), opt_cont_br; verbosity = 0)
continuation((@set probTW.jacobian = :FiniteDifferences), vcat(uold,.1), PALC(), opt_cont_br; verbosity = 0)
