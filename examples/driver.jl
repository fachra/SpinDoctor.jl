# LSP indexing solution
# https://github.com/julia-vscode/julia-vscode/issues/800#issuecomment-650085983
if isdefined(@__MODULE__, :LanguageServer)
    include("../src/SpinDoctor.jl")
    using .SpinDoctor
end

using SpinDoctor
using LinearAlgebra
using GLMakie
using OrdinaryDiffEq: Rodas4

## Chose a plotting theme
set_theme!(theme_light())
set_theme!(theme_dark())
set_theme!(theme_black())


## Create model from setup recipe
# include("setups/axon.jl")
# include("setups/sphere.jl")
# include("setups/plates.jl")
# include("setups/cylinders.jl")
# include("setups/spheres.jl")
include("setups/neuron.jl")

mesh, = @time create_geometry(setup; recreate = true);
model = Model(; mesh, coeffs...);
volumes = get_cmpt_volumes(model.mesh)
D_avg = 1 / 3 * tr.(model.D)' * volumes / sum(volumes)
@info "Number of nodes per compartment:" length.(model.mesh.points)

## Plot mesh
plot_mesh(model.mesh)

## Assemble finite element matrices
matrices = @time assemble_matrices(model);


## Magnetic field gradient
dir = [1.0, 0.0, 0.0]
profile = PGSE(2000.0, 6000.0)
# profile = CosOGSE(5000.0, 5000.0, 2)
b = 1000
g = √(b / int_F²(profile)) / coeffs.γ
gradient = ScalarGradient(dir, profile, g)


## Solve BTPDE

# Callbacks for time stepping (plot solution, save time series)
printer = Printer(; nupdate = 1, verbosity = 2)
writer = VTKWriter(; nupdate = 5)
plotter = Plotter{T}(; nupdate = 5)
# callbacks = [printer, plotter]
callbacks = [printer, plotter, writer]

# General BTPDE for all gradients
btpde = GeneralBTPDE(;
    model,
    matrices,
    reltol = 1e-4,
    abstol = 1e-6,
    odesolver = Rodas4(autodiff = false),
)

# BTPDE specialized for `ScalarGradient`s with constant interval profiles (PGSE, DoublePGSE)
btpde = IntervalConstantBTPDE{T}(; model, matrices, θ = 0.5, timestep = 5)

# Solve BTPDE
ξ = @time solve(btpde, gradient; callbacks)


## Plot magnetization
plot_field(model.mesh, ξ)

## Compute signal
compute_signal(matrices.M, ξ)
compute_signal.(matrices.M_cmpts, split_field(model.mesh, ξ))

## Save magnetization
savefield(model.mesh, ξ, "output/magnetization")


## Matrix Formalism

# Perform Laplace eigendecomposition
laplace = Laplace{T}(; model, matrices, neig_max = 400)
lap_eig = @time solve(laplace)
length_scales = eig2length.(lap_eig.values, D_avg)

# Truncate basis at minimum length scale
length_scale = 3
λ_max = length2eig(length_scale, D_avg)
lap_eig = limit_lengthscale(lap_eig, λ_max)

# Compute magnetization using the matrix formalism reduced order model
mf = MatrixFormalism(; model, matrices, lap_eig, ninterval = 500)
ξ = @time solve(mf, gradient)


## Solve HADC
hadc = HADC(; model, matrices, reltol = 1e-4, abstol = 1e-6)
adc_cmpts = @time solve(hadc, gradient)


## Solve Karger model

# Compute HADC and fit difftensors
directions = unitsphere(50)
gradients = [
    ScalarGradient(collect(d), gradient.profile, gradient.amplitude) for
    d ∈ eachcol(directions)
]
hadc = HADC(; model, matrices, reltol = 1e-4, abstol = 1e-6)
adcs, = @time solve_multigrad(hadc, gradients)
difftensors = fit_tensors(directions, adcs)

# Solve Karger
karger = Karger(; model, difftensors, timestep = 5.0)
signal = @time solve(karger, gradient)


## Solve analytical model
# Compute analytical Laplace eigenfunctions
length_scale = 0.3
eigstep = 1e-8
eiglim = length2eig(length_scale, D_avg)
analytical_coeffs = analytical_coefficients(setup, coeffs)
analytical_laplace = AnalyticalLaplace(; analytical_coeffs..., eiglim, eigstep)
lap_mat = @time solve(analytical_laplace)

# Compute analytical matrix formalism signal truncation
analytical_mf = AnalyticalMatrixFormalism(; analytical_laplace, lap_mat, volumes)
signal = solve(analytical_mf, gradient)
