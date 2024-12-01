using Revise
using LinearAlgebra, KrylovKit

using BifurcationKit
const BK = BifurcationKit

TY = Float64
AF = Array{TY}
####################################################################################################

using CUDA
CUDA.allowscalar(false)
import LinearAlgebra: mul!, axpby!
mul!(x::CuArray, y::CuArray, α::T) where {T <: Number} = (x .= α .* y)
mul!(x::CuArray, y::T, α::CuArray) where {T <: Number} = (x .= α .* y)
axpby!(a::T, X::CuArray, b::T, Y::CuArray) where {T <: Number} = (Y .= a .* X .+ b .* Y)

TY = Float64
AF = CuArray{TY}
####################################################################################################
using Plots
# to simplify plotting of the solution
plotsol(x; k...) = heatmap(reshape(Array(x), Nx, Ny)'; color=:viridis, k...)
plotsol!(x; k...) = heatmap!(reshape(Array(x), Nx, Ny)'; color=:viridis, k...)
norminf(x) = maximum(abs.(x))
####################################################################################################
using AbstractFFTs, FFTW, KrylovKit
import Base: *, \

# Making the linear operator a subtype of BK.LinearSolver is handy as we will use it
# in the Newton iterations.
struct SHLinearOp{Treal, Tcomp, Tl1, Tplan, Tiplan} <: BK.AbstractIterativeLinearSolver
    tmp_real::Treal         # temporary
    tmp_complex::Tcomp      # temporary
    l1::Tl1
    fftplan::Tplan
    ifftplan::Tiplan
end

struct SHEigOp{Tsh <: SHLinearOp, Tσ} <: BK.AbstractEigenSolver
    sh::Tsh
    σ::Tσ
end

function SHLinearOp(Nx, lx, Ny, ly; AF = Array{TY})
    # AF is a type, it could be CuArray{TY} to run the following on GPU
    k1 = vcat(collect(0:Nx/2), collect(Nx/2+1:Nx-1) .- Nx)
    k2 = vcat(collect(0:Ny/2), collect(Ny/2+1:Ny-1) .- Ny)
    d2 = [(1-(pi/lx * kx)^2 - (pi/ly * ky)^2)^2 + 1. for kx in k1, ky in k2]
    tmpc = Complex.(AF(zeros(Nx, Ny)))
    return SHLinearOp(AF(zeros(Nx, Ny)), tmpc, AF(d2), plan_fft!(tmpc), plan_ifft!(tmpc))
end

function apply(c::SHLinearOp, u, multiplier, op = *)
    c.tmp_complex .= Complex.(u)
    c.fftplan * c.tmp_complex
    c.tmp_complex .= op.(c.tmp_complex, multiplier)
    c.ifftplan * c.tmp_complex
    c.tmp_real .= real.(c.tmp_complex)
    return copy(c.tmp_real)
end

*(c::SHLinearOp, u) = apply(c, u, c.l1)
\(c::SHLinearOp, u) = apply(c, u, c.l1, /)
####################################################################################################
Nx = 2^9
Ny = 2^9
lx = 8pi * 2
ly = 2*2pi/sqrt(3) * 2

X = -lx .+ 2lx/Nx * collect(0:Nx-1)
Y = -ly .+ 2ly/Ny * collect(0:Ny-1)

sol0 = [(cos(x) .+ cos(x/2) * cos(sqrt(3) * y/2) ) for x in X, y in Y]
sol0 .= sol0 .- minimum(vec(sol0))
sol0 ./= maximum(vec(sol0))
sol0 = sol0 .- 0.25
sol0 .*= 1.7
# heatmap(sol0, color=:viridis)

function (sh::SHLinearOp)(J, rhs; shift = 0., rtol =  1e-9)
    u, l, ν = J
    udiag = l .+ 1 .+ (2ν) .* u .- 3 .* u.^2 .- shift
    res, info = KrylovKit.linsolve( du -> -du .+ sh \ (udiag .* du), sh \ rhs; rtol, maxiter = 6, ishermitian = true)
    return res, true, info.numops
end

function (sheig::SHEigOp)(J, nev::Int; kwargs...)
    u, l, ν = J
    sh = sheig.sh
    σ = sheig.σ
    A = du -> sh(J, du; shift = σ)[1]

    # we adapt the krylov dimension as function of the requested eigenvalue number
    vals, vec, info = KrylovKit.eigsolve(A, sh \ AF(rand(eltype(u), size(u))), nev, :LM, tol = 1e-10, maxiter = 20, verbosity = 2, ishermitian = true, krylovdim = max(30, nev + 10))
    @show 1 ./vals .+ σ
    return 1 ./vals .+ σ, vec, true, info.numops
end

function F_shfft(u, p)
    (;l, ν, L) = p
    return -(L * u) .+ ((l+1) .* u .+ ν .* u.^2 .- u.^3)
end

J_shfft(u, p) = (u, p.l, p.ν)

L = SHLinearOp(Nx, lx, Ny, ly, AF = AF)
Leig = SHEigOp(L, 0.1) # for eigenvalues computation
# Leig((sol_hexa, -0.1, 1.3), 20; σ = 0.5)

par = (l = -0.15, ν = 1.3, L = L)

@time F_shfft(AF(sol0), par); # 0.008022 seconds (12 allocations: 1.500 MiB)

prob = BK.BifurcationProblem(F_shfft, AF(sol0), par, (@optic _.l) ;
    J =  J_shfft,
    plot_solution = (x, p;kwargs...) -> plotsol!(x; color=:viridis, kwargs...),
    record_from_solution = (x, p; k...) -> norm(x))

opt_new = NewtonPar(verbose = true, tol = 1e-6, linsolver = L, eigsolver = Leig)
sol_hexa = @time BK.solve(prob, Newton(), opt_new, normN = norminf);
println("--> norm(sol) = ", norminf(sol_hexa.u))

plotsol(sol_hexa.u)
####################################################################################################
deflationOp = DeflationOperator(2, 1.0, [sol_hexa.u])

opt_new = @set opt_new.max_iterations = 250
outdef = @time BK.solve(re_make(prob, u0 = 0.4 .* sol_hexa.u .* AF([exp(-1(x+0lx)^2/25) for x in X, y in Y])),
            deflationOp, opt_new, normN = x -> maximum(abs, x))
println("--> norm(sol) = ", norm(outdef.u))
plotsol(outdef.u) |> display
BK.converged(outdef) && push!(deflationOp, outdef.u)
####################################################################################################
opts_cont = ContinuationPar(dsmin = 0.001, dsmax = 0.007, ds= -0.005, p_max = 0.005, p_min = -1.0, plot_every_step = 10, newton_options = setproperties(opt_new; tol = 1e-6, max_iterations = 15), max_steps = 88,
    detect_bifurcation = 0,
    tol_stability = 1e-5,
    save_eigenvectors = false,
    nev = 11 )

prob = re_make(prob, u0 = deflationOp[1])

br = @time continuation(prob, 
                        PALC(bls = BorderingBLS(solver = L, check_precision = false)), 
                        opts_cont;
                        plot = true, verbosity = 3, normC = norminf,
                        )
####################################################################################################
# computation of normal form
# we collect the matrix-free derivatives
nf = get_normal_form(br, 2)