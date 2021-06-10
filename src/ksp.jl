
const CKSP = Ptr{Cvoid}
const CKSPType = Cstring


mutable struct KSP{T} <: Factorization{T}
    ptr::CKSP
    comm::MPI.Comm
    # keep around so that they don't get gc'ed
    gc_data::Tuple
    opts::Options{T}
end

scalartype(::KSP{T}) where {T} = T

# allows us to pass XXMat objects directly into CMat ccall signatures
Base.cconvert(::Type{CKSP}, obj::KSP) = obj.ptr
# allows us to pass XXMat objects directly into Ptr{CMat} ccall signatures
Base.unsafe_convert(::Type{Ptr{CKSP}}, obj::KSP) =
    convert(Ptr{CKSP}, pointer_from_objref(obj))

Base.eltype(::KSP{T}) where {T} = T
LinearAlgebra.transpose(ksp) = LinearAlgebra.Transpose(ksp)
LinearAlgebra.adjoint(ksp) = LinearAlgebra.Adjoint(ksp)

@for_libpetsc begin

    function KSP{$PetscScalar}(comm::MPI.Comm; kwargs...)
        initialize($PetscScalar)
        opts = Options{$PetscScalar}(kwargs...)
        ksp = KSP{$PetscScalar}(C_NULL, comm, (), opts)
        @chk ccall((:KSPCreate, $libpetsc), PetscErrorCode, (MPI.MPI_Comm, Ptr{CKSP}), comm, ksp)
        if comm == MPI.COMM_SELF
            finalizer(destroy, ksp)
        end
        return ksp
    end

    function destroy(ksp::KSP{$PetscScalar})
        finalized($PetscScalar) ||
        @chk ccall((:KSPDestroy, $libpetsc), PetscErrorCode, (Ptr{CKSP},), ksp)
        return nothing
    end

    function setoperators!(ksp::KSP{$PetscScalar}, A::AbstractMat{$PetscScalar}, P::AbstractMat{$PetscScalar})
        @chk ccall((:KSPSetOperators, $libpetsc), PetscErrorCode, (CKSP, CMat, CMat), ksp, A, P)
        ksp.gc_data = (ksp.gc_data..., A, P)
        return nothing
    end

    function KSPSetDM!(ksp::KSP{$PetscScalar}, dm::AbstractDM{$PetscScalar})
        @chk ccall((:KSPSetDM, $libpetsc), PetscErrorCode, (CKSP, CDM), ksp, dm)
        ksp.gc_data = (ksp.gc_data..., dm)
        return nothing
    end

    function settolerances!(ksp::KSP{$PetscScalar}; rtol=PETSC_DEFAULT, atol=PETSC_DEFAULT, divtol=PETSC_DEFAULT, max_it=PETSC_DEFAULT)
        @chk ccall((:KSPSetTolerances, $libpetsc), PetscErrorCode, 
                    (CKSP, $PetscReal, $PetscReal, $PetscReal, $PetscInt),
                    ksp, rtol, atol, divtol, max_it)
        return nothing
    end

    function setfromoptions!(ksp::KSP{$PetscScalar})
        @chk ccall((:KSPSetFromOptions, $libpetsc), PetscErrorCode, (CKSP,), ksp)
    end

    function gettype(ksp::KSP{$PetscScalar})
        t_r = Ref{CKSPType}()
        @chk ccall((:KSPGetType, $libpetsc), PetscErrorCode, (CKSP, Ptr{CKSPType}), ksp, t_r)
        return unsafe_string(t_r[])
    end

    function iters(ksp::KSP{$PetscScalar})
        r_its = Ref{$PetscInt}()
        @chk ccall((:KSPGetIterationNumber, $libpetsc), PetscErrorCode, 
        (KSP, Ptr{$PetscInt}), ksp, r_its)
        return r_its[]
    end

    function view(ksp::KSP{$PetscScalar}, viewer::Viewer{$PetscScalar}=ViewerStdout{$PetscScalar}(ksp.comm))
        @chk ccall((:KSPView, $libpetsc), PetscErrorCode, 
                    (CKSP, CPetscViewer),
                ksp, viewer);
        return nothing
    end

    function resnorm(ksp::KSP{$PetscScalar})
        r_rnorm = Ref{$PetscReal}()
        @chk ccall((:KSPGetResidualNorm, $libpetsc), PetscErrorCode, 
        (KSP, Ptr{$PetscReal}), ksp, r_rnorm)
        return r_rnorm[]
    end

    function solve!(x::AbstractVec{$PetscScalar}, ksp::KSP{$PetscScalar}, b::AbstractVec{$PetscScalar})
        with(ksp.opts) do
            @chk ccall((:KSPSolve, $libpetsc), PetscErrorCode, 
            (CKSP, CVec, CVec), ksp, b, x)
        end
        return x
    end

    function solve!(x::AbstractVec{$PetscScalar}, tksp::Transpose{T,K}, b::AbstractVec{$PetscScalar}) where {T,K <: KSP{$PetscScalar}}
        ksp = parent(tksp)
        with(ksp.opts) do
            @chk ccall((:KSPSolveTranspose, $libpetsc), PetscErrorCode, 
            (CKSP, CVec, CVec), ksp, b, x)
        end
        return x
    end

end

# no generic Adjoint solve defined, but for Real we can use Adjoint
solve!(x::AbstractVec{T}, aksp::Adjoint{T,K}, b::AbstractVec{T}) where {K <: KSP{T}} where {T<:Real} =
    solve!(x, transpose(parent(aksp)), b)

const KSPAT{T} = Union{KSP{T}, Transpose{T, KSP{T}}, Adjoint{T, KSP{T}}}

LinearAlgebra.ldiv!(x::AbstractVec{T}, ksp::KSPAT{T}, b::AbstractVec{T}) where {T} = solve!(x, ksp, b)
function LinearAlgebra.ldiv!(x::AbstractVector{T}, ksp::KSPAT{T}, b::AbstractVector{T}) where {T}
    parent(solve!(AbstractVec(x), ksp, AbstractVec(b)))
end
Base.:\(ksp::KSPAT{T}, b::AbstractVector{T}) where {T} = ldiv!(similar(b), ksp, b)


"""
    KSP(A, P; options...)

Construct a PETSc Krylov subspace solver.

Any PETSc options prefixed with `ksp_` and `pc_` can be passed as keywords.
"""
function KSP(A::AbstractMat{T}, P::AbstractMat{T}=A; kwargs...) where {T}
    ksp = KSP{T}(A.comm; kwargs...)
    setoperators!(ksp, A, P)
    with(ksp.opts) do
        setfromoptions!(ksp)
    end
    return ksp
end

"""
    KSP(da::AbstractDM; options...)

Construct a PETSc Krylov subspace solver from the distributed mesh

Any PETSc options prefixed with `ksp_` and `pc_` can be passed as keywords.

see [PETSc manual](https://www.mcs.anl.gov/petsc/petsc-current/docs/manualpages/KSP/KSPSetDM.html)
"""
function KSP(dm::AbstractDM{T}; kwargs...) where {T}
    ksp = KSP{T}(dm.comm; kwargs...)
    KSPSetDM!(ksp, dm)
    with(ksp.opts) do
        setfromoptions!(ksp)
    end
    return ksp
end

Base.show(io::IO, ksp::KSP) = _show(io, ksp)


"""
    iters(ksp::KSP)

Gets the current iteration number; if the `solve!` is complete, returns the number of iterations used.

https://www.mcs.anl.gov/petsc/petsc-current/docs/manualpages/KSP/KSPGetIterationNumber.html
"""
iters


"""
    resnorm(ksp::KSP)

Gets the last (approximate preconditioned) residual norm that has been computed.

https://www.mcs.anl.gov/petsc/petsc-current/docs/manualpages/KSP/KSPGetResidualNorm.html
"""
resnorm

