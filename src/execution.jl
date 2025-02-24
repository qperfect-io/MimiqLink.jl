"""
    struct Execution

Structure referring to an execution on the MIMIQ Services.
"""
struct Execution
    id::String
end

Base.String(ex::Execution) = ex.id
Base.string(ex::Execution) = ex.id

function Base.show(io::IO, ::MIME"text/plain", ex::Execution)
    compact = get(io, :compact, false)

    if !compact
        println(io, "Execution")
        print(io, "└── ", ex.id)
    else
        print(io, Base.typename(ex), "($(ex.id))")
    end
end
