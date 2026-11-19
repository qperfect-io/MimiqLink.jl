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
# What a MimiqConnection does against the MIMIQ API.

@testset "authentication" begin
    server = MimiqServer()

    try
        token = issuetokens!(server)["refreshToken"]
        connection = quiet(() -> connect(token; url=server.uri))

        # The server issues a new pair on every refresh, so the token that
        # opened the connection is already spent.
        @test fetch(connection.tokens_channel).refreshtoken != token
        @test fetch(connection.tokens_channel).refreshtoken == server.refreshtoken
        @test !istaskdone(connection.refresher)

        quiet(() -> close(connection))
        @test waitclosed(connection)

        # A spent token is refused.
        @test_throws ErrorException quiet(() -> connect(token; url=server.uri))

        # So are the wrong credentials, and the server's reason is reported.
        @test_throws ErrorException quiet(
            () -> connect(server.email, "not the password"; url=server.uri),
        )

        connection = quiet(() -> connect(server.email, server.password; url=server.uri))
        @test !istaskdone(connection.refresher)
        quiet(() -> close(connection))
    finally
        close(server)
    end
end

@testset "a failed refresh drops the connection" begin
    server = MimiqServer()

    try
        connection = quiet(
            () -> connect(issuetokens!(server)["refreshToken"]; url=server.uri, interval=1),
        )

        # Rotating the tokens behind the connection's back makes its next
        # refresh fail, as a revoked session would.
        issuetokens!(server)

        quiet() do
            deadline = time() + 20
            while !istaskdone(connection.refresher) && time() < deadline
                sleep(0.2)
            end
        end

        @test istaskdone(connection.refresher)

        # The refresher leaves an empty token behind rather than an empty
        # channel, so a later authheader reports a closed connection instead of
        # blocking on it.
        @test fetch(connection.tokens_channel) == M.Tokens()

        # Closing an already dropped connection is not an error.
        @test quiet(() -> close(connection)) |> isnothing
    finally
        close(server)
    end
end

@testset "user limits" begin
    server = MimiqServer()

    try
        server.limits = Dict{String, Any}(
            "enabledExecutionTime" => true,
            "usedExecutionTime" => 7200,
            "maxExecutionTime" => 3600,
            "enabledMaxExecutions" => true,
            "usedExecutions" => 11,
            "maxExecutions" => 10,
            "enabledMaxTimeout" => false,
        )

        token = issuetokens!(server)["refreshToken"]

        connection = nothing
        @test_logs (:warn,) (:warn,) match_mode = :any begin
            connection = connect(token; url=server.uri)
        end

        @test occursin("open", sprint(show, connection))

        quiet(() -> close(connection))
    finally
        close(server)
    end

    # The service can leave a limit empty.
    @test_logs MimiqLink.checklimits(
        Dict{String, Any}(
            "enabledExecutionTime" => true,
            "usedExecutionTime" => nothing,
            "maxExecutionTime" => 3600,
            "enabledMaxExecutions" => true,
            "usedExecutions" => 3,
            "maxExecutions" => nothing,
        ),
    )
end

@testset "requests" begin
    withmimiq() do server, connection
        mktempdir() do dir
            circuit = joinpath(dir, "circuit.pb")
            write(circuit, "a circuit")
            parameters = joinpath(dir, "parameters.json")
            write(parameters, "{}")

            execution =
                request(connection, "CIRC", "a name", "a label", 30, circuit, parameters)

            @test execution.id in keys(server.jobs)
            @test server.lastupload == [
                "name" => "",
                "label" => "",
                "emulatorType" => "",
                "timeout" => "",
                "uploads" => "circuit.pb",
                "uploads" => "parameters.json",
            ]
        end

        @test_throws ArgumentError request(connection, "CIRC", "a name", "a label", 0)

        job = addjob!(server, "RUNNING")
        infos = requestinfo(connection, Execution(job))
        @test infos["status"] == "RUNNING"
        @test infos["user"]["email"] == server.email

        # The server's own message is what the user sees.
        @test_throws "No request with id no-such-job" requestinfo(
            connection,
            Execution("no-such-job"),
        )

        addjob!(server, "DONE")
        @test length(requests(connection)) == 3
        @test length(requests(connection; status="DONE")) == 1

        # Printing the list is a display path with no return value to check, so
        # this only asks that it survives both a full and an empty list.
        @test quiet(() -> printrequests(connection)) === nothing
        @test quiet(() -> printrequests(connection; status="CANCELED")) === nothing
    end
end

@testset "job status" begin
    withmimiq() do server, connection
        # status => (done, started, failed, canceled)
        expected = [
            "NEW" => (false, false, false, false),
            "RUNNING" => (false, true, false, false),
            "DONE" => (true, true, false, false),
            "ERROR" => (true, true, true, false),
            "CANCELED" => (true, true, false, true),
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
    withmimiq() do server, connection
        execution = Execution(addjob!(server, "RUNNING"))

        @test stopexecution(connection, execution)
        @test server.jobs[execution.id]["status"] == "CANCELED"

        @test_throws "No request with id no-such-job" stopexecution(
            connection,
            Execution("no-such-job"),
        )

        execution = Execution(
            addjob!(server, "DONE"; results=["results.pb" => Vector{UInt8}("results")]),
        )

        @test deletefiles(connection, execution)
        @test isempty(server.files[(execution.id, "results")])
    end
end

@testset "downloads" begin
    withmimiq() do server, connection
        execution = Execution(
            addjob!(
                server,
                "DONE";
                uploads=["circuit.pb" => Vector{UInt8}("a circuit")],
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

        mktempdir() do dir
            names = quiet(() -> downloadjobfiles(connection, execution, dir))

            @test basename.(names) == ["circuit.pb"]
            @test read(joinpath(dir, "circuit.pb"), String) == "a circuit"
        end

        # A job with no files warns instead of failing.
        empty = Execution(addjob!(server, "DONE"))

        mktempdir() do dir
            @test (@test_logs (:warn,) match_mode = :any downloadresults(
                connection,
                empty,
                dir,
            )) == []
        end
    end
end
