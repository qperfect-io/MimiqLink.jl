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
# Stand-ins for the servers this package talks to.
#
# Each one is a real HTTP server on a free local port, answering the routes the
# client actually calls and keeping the state that makes the answers
# interesting: which token is current, which jobs exist, which files they
# produced. The client is not told it is being tested — it connects, refreshes
# and downloads over a socket as it would against the cloud.

import HTTP
import JSON
import Sockets

using Logging
using URIs

const JSONRESPONSE = ["Content-Type" => "application/json"]

_json(status, payload) = HTTP.Response(status, JSONRESPONSE, JSON.json(payload))

_body(req) = JSON.parse(String(HTTP.payload(req)))

_param(req, name) = HTTP.getparams(req)[name]

_query(req, name, default=nothing) = get(queryparams(URI(req.target)), name, default)

"""
    quiet(f)

Run `f` with logging silenced, to keep the connection chatter of a few dozen
connects and closes out of the test output.
"""
quiet(f) = with_logger(f, NullLogger())

"""
    waitclosed(connection)

Wait for a connection's refresher to stop, since `close` only asks it to.
"""
waitclosed(connection; timeout=10) =
    timedwait(() -> istaskdone(connection.refresher), timeout) === :ok

"""
    _serve(router)

Start a router on a free local port and return the server and its URI.
"""
function _serve(router)
    server = quiet(() -> HTTP.serve!(router, Sockets.localhost, 1500; listenany=true))
    return server, URI("http://127.0.0.1:$(HTTP.port(server))")
end

# -- MIMIQ ------------------------------------------------------------------

"""
    MimiqServer()

The MIMIQ cloud API, as much of it as the client uses.

Tokens rotate on every refresh, exactly like the real server: a refresh token
works once, and the client is expected to keep the new one.
"""
mutable struct MimiqServer
    uri::URI
    server::Any
    email::String
    password::String
    issued::Int
    accesstoken::String
    refreshtoken::String
    jobs::Dict{String, Any}
    files::Dict{Tuple{String, String}, Vector{Pair{String, Vector{UInt8}}}}
    limits::Dict{String, Any}
    lastupload::Vector{Pair{String, String}}
end

function MimiqServer()
    s = MimiqServer(
        URI(),
        nothing,
        "john.doe@example.com",
        "johnspassword",
        0,
        "",
        "",
        Dict{String, Any}(),
        Dict{Tuple{String, String}, Vector{Pair{String, Vector{UInt8}}}}(),
        Dict{String, Any}(
            "enabledExecutionTime" => false,
            "enabledMaxExecutions" => false,
            "enabledMaxTimeout" => false,
        ),
        Pair{String, String}[],
    )

    router = HTTP.Router()
    HTTP.register!(router, "POST", "/api/sign-in", req -> _signin(s, req))
    HTTP.register!(router, "POST", "/api/access-token", req -> _accesstoken(s, req))
    HTTP.register!(router, "GET", "/api/users/limits", req -> _userlimits(s, req))
    HTTP.register!(router, "POST", "/api/request", req -> _newjob(s, req))
    HTTP.register!(router, "GET", "/api/request", req -> _joblist(s, req))
    HTTP.register!(router, "GET", "/api/request/{id}", req -> _job(s, req))
    HTTP.register!(router, "POST", "/api/stop-execution/{id}", req -> _stop(s, req))
    HTTP.register!(router, "POST", "/api/delete-files/{id}", req -> _deletefiles(s, req))
    HTTP.register!(router, "GET", "/api/files/{id}/{index}", req -> _downloadfile(s, req))

    s.server, s.uri = _serve(router)

    return s
end

Base.close(s::MimiqServer) = quiet(() -> close(s.server))

"""
    issuetokens!(server)

Issue a fresh token pair, invalidating the previous one.
"""
function issuetokens!(s::MimiqServer)
    s.issued += 1
    s.accesstoken = "access-$(s.issued)"
    s.refreshtoken = "refresh-$(s.issued)"

    return Dict("token" => s.accesstoken, "refreshToken" => s.refreshtoken)
end

"""
    addjob!(server[, status]; uploads, results)

Add a job to the server and return its identifier. `uploads` and `results` are
`filename => content` pairs, and the counts the client reads back are derived
from them.
"""
function addjob!(
    s::MimiqServer,
    status::AbstractString="NEW";
    uploads=Pair{String, Vector{UInt8}}[],
    results=Pair{String, Vector{UInt8}}[],
)
    id = "job-$(length(s.jobs) + 1)"

    s.jobs[id] = Dict{String, Any}(
        "_id" => id,
        "name" => "circuit",
        "label" => "a label",
        "status" => status,
        "user" => Dict("email" => s.email),
        "creationDate" => "2026-01-01T00:00:00.000Z",
        "numberOfUploadedFiles" => length(uploads),
        "numberOfResultedFiles" => length(results),
    )

    s.files[(id, "uploads")] = collect(uploads)
    s.files[(id, "results")] = collect(results)

    return id
end

_authorized(s::MimiqServer, req) =
    HTTP.header(req, "Authorization") == "Bearer " * s.accesstoken

function _signin(s::MimiqServer, req)
    credentials = _body(req)

    if get(credentials, "email", "") != s.email ||
       get(credentials, "password", "") != s.password
        return _json(401, Dict("message" => "Wrong email or password"))
    end

    return _json(200, issuetokens!(s))
end

function _accesstoken(s::MimiqServer, req)
    if get(_body(req), "refreshToken", "") != s.refreshtoken
        return _json(401, Dict("message" => "The refresh token is no longer valid"))
    end

    return _json(200, issuetokens!(s))
end

function _userlimits(s::MimiqServer, req)
    _authorized(s, req) || return _json(401, Dict("message" => "Unauthorized"))

    return _json(200, s.limits)
end

function _newjob(s::MimiqServer, req)
    _authorized(s, req) || return _json(401, Dict("message" => "Unauthorized"))

    parts = HTTP.parse_multipart_form(req)
    s.lastupload = [part.name => something(part.filename, "") for part in parts]

    uploads = [
        String(part.filename) => Vector{UInt8}(take!(part.data)) for
        part in parts if !isnothing(part.filename)
    ]

    return _json(200, Dict("executionRequestId" => addjob!(s; uploads)))
end

function _job(s::MimiqServer, req)
    id = _param(req, "id")

    haskey(s.jobs, id) || return _json(404, Dict("message" => "No request with id $(id)"))

    return _json(200, s.jobs[id])
end

function _joblist(s::MimiqServer, req)
    status = _query(req, "status")

    docs = [job for job in values(s.jobs) if isnothing(status) || job["status"] == status]

    return _json(200, Dict("executions" => Dict("docs" => docs)))
end

function _stop(s::MimiqServer, req)
    id = _param(req, "id")

    haskey(s.jobs, id) || return _json(404, Dict("message" => "No request with id $(id)"))

    s.jobs[id]["status"] = "CANCELED"

    return _json(200, Dict())
end

function _deletefiles(s::MimiqServer, req)
    id = _param(req, "id")

    haskey(s.jobs, id) || return _json(404, Dict("message" => "No request with id $(id)"))

    empty!(s.files[(id, "uploads")])
    empty!(s.files[(id, "results")])

    return _json(200, Dict())
end

function _downloadfile(s::MimiqServer, req)
    id = _param(req, "id")
    index = parse(Int, _param(req, "index"))
    source = something(_query(req, "source"), "results")

    files = get(s.files, (id, source), Pair{String, Vector{UInt8}}[])

    index < length(files) || return _json(404, Dict("message" => "No such file"))

    name, content = files[index + 1]

    return HTTP.Response(
        200,
        ["Content-Disposition" => "attachment; filename=\"$(name)\""],
        content,
    )
end

# -- Quantum Hive -----------------------------------------------------------

"""
    QhiveServer()

The Quantum Hive API together with the Keycloak realm in front of it.

Set `expireonce` to have the next authenticated call refused once, which is how
a test says that an access token went stale without waiting for one to expire.
"""
mutable struct QhiveServer
    uri::URI
    server::Any
    email::String
    password::String
    issued::Int
    accesstoken::String
    refreshtoken::String
    expireonce::Bool
    refuseuploads::Bool
    jobs::Dict{String, Any}
    files::Dict{Tuple{String, String}, Vector{Pair{String, Vector{UInt8}}}}
    circuits::Dict{String, Vector{String}}
    committed::Vector{String}
end

function QhiveServer(; realm="qhive")
    s = QhiveServer(
        URI(),
        nothing,
        "john.doe@example.com",
        "johnspassword",
        0,
        "",
        "",
        false,
        false,
        Dict{String, Any}(),
        Dict{Tuple{String, String}, Vector{Pair{String, Vector{UInt8}}}}(),
        Dict{String, Vector{String}}(),
        String[],
    )

    oidc = "/auth/realms/$(realm)/protocol/openid-connect"

    router = HTTP.Router()
    HTTP.register!(router, "POST", "$(oidc)/token", req -> _token(s, req))
    HTTP.register!(router, "GET", "$(oidc)/userinfo", req -> _userinfo(s, req))
    HTTP.register!(router, "POST", "$(oidc)/logout", req -> _qhivelogout(s, req))

    HTTP.register!(router, "POST", "/api/jobs", req -> _qhivenewjob(s, req))
    HTTP.register!(router, "GET", "/api/jobs", req -> _qhivejoblist(s, req))
    HTTP.register!(router, "GET", "/api/jobs/{id}", req -> _qhivejob(s, req))
    HTTP.register!(router, "PATCH", "/api/jobs/{id}/commit", req -> _commit(s, req))
    HTTP.register!(router, "PATCH", "/api/jobs/{id}/cancel", req -> _qhivecancel(s, req))
    HTTP.register!(
        router,
        "POST",
        "/api/files/{id}/circuit/{name}",
        req -> _uploadcircuit(s, req),
    )
    HTTP.register!(router, "DELETE", "/api/files/{id}", req -> _qhivedeletefiles(s, req))
    HTTP.register!(router, "GET", "/api/files/{id}/{source}", req -> _filelist(s, req))
    HTTP.register!(router, "GET", "/download/{name}", req -> _download(s, req))

    s.server, s.uri = _serve(router)

    return s
end

Base.close(s::QhiveServer) = quiet(() -> close(s.server))

function issuetokens!(s::QhiveServer)
    s.issued += 1
    s.accesstoken = "access-$(s.issued)"
    s.refreshtoken = "refresh-$(s.issued)"

    return Dict(
        "access_token" => s.accesstoken,
        "refresh_token" => s.refreshtoken,
        "expires_in" => 300,
        "token_type" => "Bearer",
    )
end

function addjob!(
    s::QhiveServer,
    status::AbstractString="AUTHORIZED";
    results=Pair{String, Vector{UInt8}}[],
)
    id = "job-$(length(s.jobs) + 1)"

    s.jobs[id] = Dict{String, Any}(
        "_id" => id,
        "algorithm" => "circuit",
        "label" => "a label",
        "status" => status,
    )

    s.files[(id, "results")] = collect(results)
    s.circuits[id] = String[]

    return id
end

function _authorized(s::QhiveServer, req)
    HTTP.header(req, "Authorization") == "Bearer " * s.accesstoken || return false

    if s.expireonce
        s.expireonce = false
        return false
    end

    return true
end

_expired() = _json(401, Dict("error_description" => "Expired token"))

function _token(s::QhiveServer, req)
    form = queryparams(String(HTTP.payload(req)))
    grant = get(form, "grant_type", "")

    if grant == "password"
        if get(form, "username", "") != s.email || get(form, "password", "") != s.password
            return _json(401, Dict("error_description" => "Invalid user credentials"))
        end
    elseif grant == "refresh_token"
        if get(form, "refresh_token", "") != s.refreshtoken
            return _json(400, Dict("error_description" => "Invalid refresh token"))
        end
    elseif grant == "authorization_code"
        if get(form, "code", "") != "the-code"
            return _json(400, Dict("error_description" => "Invalid authorization code"))
        end
    else
        return _json(400, Dict("error_description" => "Unsupported grant $(grant)"))
    end

    return _json(200, issuetokens!(s))
end

function _userinfo(s::QhiveServer, req)
    if HTTP.header(req, "Authorization") != "Bearer " * s.accesstoken
        return _json(401, Dict("error_description" => "Invalid token"))
    end

    return _json(200, Dict("sub" => "1234", "email" => s.email))
end

function _qhivelogout(s::QhiveServer, req)
    s.accesstoken = ""
    s.refreshtoken = ""

    return HTTP.Response(204)
end

function _qhivenewjob(s::QhiveServer, req)
    _authorized(s, req) || return _expired()

    return HTTP.Response(200, addjob!(s, "NEW"))
end

function _uploadcircuit(s::QhiveServer, req)
    _authorized(s, req) || return _expired()

    s.refuseuploads && return _json(500, Dict("message" => "Refused"))

    id = _param(req, "id")

    haskey(s.jobs, id) || return _json(404, Dict("message" => "No such job"))

    push!(s.circuits[id], _param(req, "name"))

    return HTTP.Response(201)
end

function _commit(s::QhiveServer, req)
    _authorized(s, req) || return _expired()

    id = _param(req, "id")
    push!(s.committed, id)
    s.jobs[id]["status"] = "COMMITED"

    return _json(200, Dict())
end

function _qhivecancel(s::QhiveServer, req)
    _authorized(s, req) || return _expired()

    s.jobs[_param(req, "id")]["status"] = "CANCELED"

    return _json(200, Dict())
end

function _qhivejob(s::QhiveServer, req)
    _authorized(s, req) || return _expired()

    id = _param(req, "id")

    haskey(s.jobs, id) || return _json(404, Dict("message" => "No such job"))

    return _json(200, s.jobs[id])
end

function _qhivejoblist(s::QhiveServer, req)
    _authorized(s, req) || return _expired()

    return _json(200, collect(values(s.jobs)))
end

function _qhivedeletefiles(s::QhiveServer, req)
    _authorized(s, req) || return _expired()

    id = _param(req, "id")

    # The API answers 200 to say it refused, and 202 once the files are
    # scheduled for deletion.
    if get(get(s.jobs, id, Dict()), "status", "") ∉ ("SUCCESSFUL", "ERROR")
        return _json(200, Dict("message" => "The job is not completed"))
    end

    empty!(s.files[(id, "results")])

    return _json(202, Dict())
end

function _filelist(s::QhiveServer, req)
    _authorized(s, req) || return _expired()

    id = _param(req, "id")
    source = _param(req, "source")

    files = get(s.files, (id, source), Pair{String, Vector{UInt8}}[])

    return _json(200, ["$(s.uri)/download/$(name)" for (name, _) in files])
end

function _download(s::QhiveServer, req)
    name = _param(req, "name")

    for files in values(s.files), (filename, content) in files
        if filename == name
            return HTTP.Response(
                200,
                ["Content-Disposition" => "attachment; filename=\"$(filename)\""],
                content,
            )
        end
    end

    return _json(404, Dict("message" => "No such file"))
end

# -- fixtures ---------------------------------------------------------------

"""
    withmimiq(f)

Run `f(server, connection)` against a fresh MIMIQ server, with a connection
already authenticated, and shut both down afterwards.
"""
function withmimiq(f)
    server = MimiqServer()

    try
        connection =
            quiet(() -> connect(issuetokens!(server)["refreshToken"]; url=server.uri))
        try
            f(server, connection)
        finally
            quiet(() -> close(connection))
        end
    finally
        close(server)
    end
end

"""
    withqhive(f)

Run `f(server, connection)` against a fresh Quantum Hive server, with a
connection already authenticated, and shut both down afterwards.
"""
function withqhive(f)
    server = QhiveServer()

    try
        connection = quiet(
            () ->
                connect(QhiveConnection, server.email, server.password; url=server.uri),
        )
        try
            f(server, connection)
        finally
            quiet(() -> close(connection))
        end
    finally
        close(server)
    end
end
