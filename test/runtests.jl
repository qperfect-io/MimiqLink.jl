using MimiqLink
using Test
using URIs

const M = MimiqLink

@testset "QHive connection" begin
    uri = URI("https://mimiqfast.qperfect.io")

    @test string(M.geturi(QhiveConnection, uri, "jobs")) ==
          "https://mimiqfast.qperfect.io/api/jobs"

    # The identity provider sits under the service, unless told otherwise.
    @test M._qhiveauthuri(uri, nothing) == URI("https://mimiqfast.qperfect.io/auth")
    @test M._qhiveauthuri(uri, "https://auth.example/") == URI("https://auth.example/")

    @test string(M._oidcuri(URI("https://auth.example"), "qhive", "token")) ==
          "https://auth.example/realms/qhive/protocol/openid-connect/token"

    # Refresh before the token expires, and never in a tight loop.
    @test M._refreshinterval(300) == 240
    @test M._refreshinterval(1) == 30

    # The two descriptors travel as form fields, every other file as a circuit.
    fields, circuits = M._qhiveuploads((
        "/tmp/job/circuits.json",
        "/tmp/job/request.json",
        "/tmp/job/circuit-1.pb",
    ))
    @test fields ==
          ["parameters" => "/tmp/job/circuits.json", "request" => "/tmp/job/request.json"]
    @test circuits == ["circuit-1.pb" => "/tmp/job/circuit-1.pb"]

    # The server names every stored file, so an anonymous stream cannot be sent.
    @test_throws ArgumentError M._qhiveuploads((IOBuffer(),))
end
