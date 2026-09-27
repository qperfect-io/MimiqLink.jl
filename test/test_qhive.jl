#
# Copyright © 2022-2026 QPerfect. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# What a QhiveConnection does against Quantum Hive and its Keycloak realm.

@testset "url and token helpers" begin
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

@testset "authentication" begin
    server = QhiveServer()

    try
        connection = quiet(
            () ->
                connect(QhiveConnection, server.email, server.password; url=server.uri),
        )

        @test fetch(connection.tokens_channel).accesstoken == server.accesstoken
        @test !istaskdone(connection.refresher)

        # Closing ends the session on the identity provider too.
        quiet(() -> close(connection))
        @test server.accesstoken == ""

        # The realm's own reason for the refusal is what the user sees.
        @test_throws "Invalid user credentials" quiet(
            () ->
                connect(QhiveConnection, server.email, "not the password"; url=server.uri),
        )

        token = issuetokens!(server)["refresh_token"]
        connection = quiet(() -> connect(QhiveConnection, token; url=server.uri))
        @test fetch(connection.tokens_channel).accesstoken == server.accesstoken
        quiet(() -> close(connection))

        @test_throws "Invalid refresh token" quiet(
            () -> connect(QhiveConnection, "not a token"; url=server.uri),
        )
    finally
        close(server)
    end
end

@testset "requests" begin
    withqhive() do server, connection
        mktempdir() do dir
            for name in ("circuits.json", "request.json")
                write(joinpath(dir, name), "{}")
            end
            write(joinpath(dir, "circuit-1.pb"), "a circuit")

            execution = request(
                connection,
                "CIRC",
                "a name",
                "a label",
                30,
                joinpath(dir, "circuits.json"),
                joinpath(dir, "request.json"),
                joinpath(dir, "circuit-1.pb"),
            )

            # The two descriptors travel with the job, every other file on its own.
            @test server.circuits[execution.id] == ["circuit-1.pb"]
            @test server.committed == [execution.id]
            @test server.jobs[execution.id]["status"] == "COMMITED"
        end

        @test_throws ArgumentError request(connection, "CIRC", "a name", "a label", 0)

        job = addjob!(server, "PROCESSED")
        @test requestinfo(connection, Execution(job))["status"] == "PROCESSED"

        addjob!(server, "SUCCESSFUL")
        @test length(requests(connection)) == 3
    end
end

@testset "a job whose upload fails is never committed" begin
    withqhive() do server, connection
        server.refuseuploads = true

        mktempdir() do dir
            circuit = joinpath(dir, "circuit-1.pb")
            write(circuit, "a circuit")

            @test_throws ErrorException request(
                connection,
                "CIRC",
                "a name",
                "a label",
                30,
                circuit,
            )
        end

        @test isempty(server.committed)
    end
end

@testset "job status" begin
    withqhive() do server, connection
        # status => (done, started, failed, canceled)
        #
        # A canceled job counts as done here, unlike the Python client, which
        # reports it as still running and leaves a polling loop spinning.
        expected = [
            "NEW" => (false, false, false, false),
            "AUTHORIZED" => (false, true, false, false),
            "COMMITED" => (false, true, false, false),
            "PROCESSED" => (false, true, false, false),
            "SUCCESSFUL" => (true, false, false, false),
            "ERROR" => (true, false, true, false),
            "CANCELED" => (true, false, false, true),
        ]

        for (status, (done, started, failed, canceled)) in expected
            execution = Execution(addjob!(server, status))

            @test isjobdone(connection, execution) == done
            @test isjobstarted(connection, execution) == started
            @test isjobfailed(connection, execution) == failed
            @test isjobcanceled(connection, execution) == canceled
        end
    end
end

@testset "controlling a job" begin
    withqhive() do server, connection
        execution = Execution(addjob!(server, "PROCESSED"))

        @test stopexecution(connection, execution)
        @test server.jobs[execution.id]["status"] == "CANCELED"

        finished = Execution(
            addjob!(
                server,
                "SUCCESSFUL";
                results=["samples.pb" => Vector{UInt8}("samples")],
            ),
        )

        @test deletefiles(connection, finished)
        @test isempty(server.files[(finished.id, "results")])

        # The files of a job that is still running are kept.
        running = Execution(
            addjob!(
                server,
                "PROCESSED";
                results=["samples.pb" => Vector{UInt8}("samples")],
            ),
        )

        @test_throws "not completed" deletefiles(connection, running)
    end
end

@testset "downloads" begin
    withqhive() do server, connection
        execution = Execution(
            addjob!(
                server,
                "SUCCESSFUL";
                results=[
                    "amplitudes.pb" => Vector{UInt8}("amplitudes"),
                    "samples.pb" => Vector{UInt8}("samples"),
                ],
            ),
        )

        mktempdir() do dir
            names = quiet(() -> downloadresults(connection, execution, dir))

            @test sort(basename.(names)) == ["amplitudes.pb", "samples.pb"]
            @test read(joinpath(dir, "samples.pb"), String) == "samples"
        end

        empty = Execution(addjob!(server, "SUCCESSFUL"))

        mktempdir() do dir
            @test (@test_logs (:warn,) match_mode = :any downloadresults(
                connection,
                empty,
                dir,
            )) == String[]
        end
    end
end
