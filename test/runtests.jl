using MimiqLink
using Test
using URIs

const M = MimiqLink

include("servers.jl")

@testset "MimiqLink" begin
    @testset "MimiqConnection" begin
        include("test_mimiq.jl")
    end

    @testset "QhiveConnection" begin
        include("test_qhive.jl")
    end
end
