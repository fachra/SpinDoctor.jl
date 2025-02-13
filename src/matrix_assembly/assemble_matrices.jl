"""
    assemble_matrices(model)

Assemble finite element matrices.
"""
function assemble_matrices(model)
    (; mesh, D, T₂, ρ) = model

    # Deduce sizes
    ncompartment, nboundary = size(mesh.facets)
    npoint_cmpts = size.(mesh.points, 2)

    # Assemble finite element matrices
    volumes = zeros(ncompartment)
    for icmpt = 1:ncompartment
        points = mesh.points[icmpt]
        elements = mesh.elements[icmpt]
        fevolumes, = get_mesh_volumes(points, elements)
        volumes[icmpt] = sum(fevolumes)
    end

    # Assemble finite element matrices compartment-wise
    M_cmpts = []
    S_cmpts = []
    Mx_cmpts = [[] for _ = 1:3]
    G = []
    for icmpt = 1:ncompartment
        # Finite elements
        points = mesh.points[icmpt]
        elements = mesh.elements[icmpt]
        fevolumes, = get_mesh_volumes(points, elements)

        # Assemble mass, stiffness and flux matrices
        push!(M_cmpts, assemble_mass_matrix(elements', fevolumes))
        push!(S_cmpts, assemble_stiffness_matrix(elements', points', D[icmpt]))

        # Assemble first order product moment matrices
        for dim = 1:3
            push!(Mx_cmpts[dim], assemble_mass_matrix(elements', fevolumes, points[dim, :]))
        end

        # Compute surface integrals
        push!(G, zeros(npoint_cmpts[icmpt], 3))
        for iboundary = 1:nboundary
            facets = mesh.facets[icmpt, iboundary]
            if !isempty(facets)
                # Get facet normals
                _, _, normals = get_mesh_surfacenormals(points, elements, facets)

                # Surface normal weighted flux matrix (in each canonical direction)
                for dim = 1:3
                    Q = assemble_flux_matrix(facets', points', normals[dim, :])
                    G[icmpt][:, dim] += sum(Q, dims = 2)
                end
            end
        end

    end

    # Assemble global finite element matrices
    M = blockdiag(M_cmpts...)
    S = blockdiag(S_cmpts...)
    R = blockdiag((M_cmpts ./ T₂)...)
    Mx = [blockdiag(Mx_cmpts[dim]...) for dim = 1:3]
    Q_blocks = assemble_flux_matrices(mesh.points, mesh.facets)
    Q = couple_flux_matrix(model, Q_blocks, false)

    (; M, S, R, Mx, Q, M_cmpts, S_cmpts, Mx_cmpts, G, volumes)
end
