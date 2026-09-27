#
# Copyright © 2022-2024 University of Strasbourg. All Rights Reserved.
# Copyright © 2023-2026 QPerfect. All Rights Reserved.
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
using Random

"""
    const QHIVE_REALM

Keycloak realm authenticating the Quantum Hive services.
"""
const QHIVE_REALM = "qhive"

"""
    const QHIVE_CLIENT_ID

Keycloak client the library authenticates as.
"""
const QHIVE_CLIENT_ID = "qhive-frontend"

# Job states reported by the Quantum Hive API. A job that has not reached any
# of them is still waiting to be authorized.
const QHIVE_STARTED_STATUSES = ("AUTHORIZED", "COMMITED", "PROCESSED")
const QHIVE_DONE_STATUSES = ("SUCCESSFUL", "ERROR", "CANCELED")

# The API takes the job parameters and the request descriptor as form fields and
# every circuit as a separate upload, so uploads are split by file name.
const QHIVE_FORM_FILES = Dict("circuits.json" => "parameters", "request.json" => "request")

# Uploads and results are stored under these names, and not under the ones the
# MIMIQ API uses.
const QHIVE_FILE_SOURCES = Dict(:uploads => "circuit", :results => "results")

const FORMHEADERS = ["Content-Type" => "application/x-www-form-urlencoded"]

_oidcuri(authuri::URI, realm::AbstractString, endpoint::AbstractString) =
    joinpath(authuri, "realms", realm, "protocol", "openid-connect", endpoint)

# Keycloak reports failures as `error` and `error_description`, and not through
# the `message` field that `_checkresponse` looks for.
function _oidcerror(res::HTTP.Response, prefix)
    payload = String(HTTP.payload(res))

    detail = try
        json = JSON.parse(payload)
        get(json, "error_description", get(json, "error", payload))
    catch
        payload
    end

    error(lazy"$(prefix): $(detail)")
end

"""
    _qhivetokens(authuri, realm, clientid, params)

Ask the identity provider for a token with the given grant parameters.

Returns the tokens and the lifetime in seconds of the access token.
"""
function _qhivetokens(
    authuri::URI,
    realm::AbstractString,
    clientid::AbstractString,
    params::Dict{String, String},
)
    body = URIs.escapeuri(merge(Dict("client_id" => clientid), params))

    res = HTTP.post(
        _oidcuri(authuri, realm, "token"),
        FORMHEADERS,
        body;
        status_exception=false,
    )

    if HTTP.iserror(res)
        _oidcerror(res, "Failed to authenticate to the Quantum Hive services")
    end

    json = JSON.parse(String(HTTP.payload(res)))

    return Tokens(json["access_token"], json["refresh_token"]), json["expires_in"]
end

_qhiverefresh(authuri::URI, realm, clientid, tokens::Tokens) = _qhivetokens(
    authuri,
    realm,
    clientid,
    Dict("grant_type" => "refresh_token", "refresh_token" => tokens.refreshtoken),
)

# The realm decides how long an access token lives, so refresh shortly before it
# expires instead of on a fixed interval.
_refreshinterval(expiresin) = max(floor(Int, expiresin * 0.8), 30)

"""
    struct QhiveConnection

Connection with the Quantum Hive Services.

# Attributes

* `uri`: the URI of the connected instance
* `authuri`: the URI of the identity provider
* `realm`: the Keycloak realm used for authentication
* `clientid`: the Keycloak client the library authenticates as
* `tokens_channel`: channel updated with the latest refreshed token
* `refresher`: task that refreshes the token before it expires
"""
struct QhiveConnection <: AbstractConnection
    uri::URI
    authuri::URI
    realm::String
    clientid::String
    tokens_channel::Channel{Tokens}
    refresher::Task
end

function QhiveConnection(
    uri::URI,
    authuri::URI,
    tokens::Tokens,
    expiresin::Integer;
    realm=QHIVE_REALM,
    clientid=QHIVE_CLIENT_ID,
)
    ch = Channel{Tokens}(1)
    put!(ch, tokens)

    refresher = @async begin
        interval = _refreshinterval(expiresin)
        try
            while true
                @debug "Waiting for $(interval) seconds before refreshing tokens"
                sleep(interval)

                @debug "Refreshing tokens"

                # fetch, not take!, to leave the token readable while refreshing
                newtokens, expiresin =
                    _qhiverefresh(authuri, realm, clientid, fetch(ch))

                @debug "Received new tokens" newtokens

                take!(ch)
                put!(ch, newtokens)

                interval = _refreshinterval(expiresin)
            end
        catch ex
            if isa(ex, InterruptException)
                @info "Gracefully shutting down token refresher"
            else
                # The channel may have been emptied by the refresh above, and an
                # empty one would block every later `authheader`.
                isready(ch) || put!(ch, Tokens())
                @error "Connection to Quantum Hive services dropped." exception =
                    (ex, catch_backtrace())
            end
        end
    end

    return QhiveConnection(uri, authuri, realm, clientid, ch, refresher)
end

function Base.show(io::IO, conn::QhiveConnection)
    compact = get(io, :compact, false)

    if !compact
        status = istaskdone(conn.refresher) ? "closed" : "open"
        println(io, "QhiveConnection:")
        println(io, "├── url: ", conn.uri)
        println(io, "├── auth url: ", conn.authuri)
        print(io, "└── status: ", status)
    else
        print(io, typeof(conn), "($(conn.uri))")
    end

    nothing
end

geturi(::Type{QhiveConnection}, uri::URI) = joinpath(uri, "api")
geturi(::Type{QhiveConnection}, uri::URI, paths...) = joinpath(uri, "api", paths...)
geturi(conn::QhiveConnection) = joinpath(conn.uri, "api")
geturi(conn::QhiveConnection, paths...) = joinpath(conn.uri, "api", paths...)

# Authentication header. To be used in function with
# `headers = [authheader(conn), "OtherHeader" => "headervalue", ...]`
function authheader(conn::QhiveConnection)
    # fetch, not take!, otherwise next time we have to wait for a put! in the channel
    tokens = fetch(conn.tokens_channel)
    return "Authorization" => "Bearer " * tokens.accesstoken
end

function Base.close(conn::QhiveConnection)
    @info "Closing Quantum Hive connection to $(conn.uri)"

    tokens = fetch(conn.tokens_channel)

    if !isempty(tokens.refreshtoken)
        try
            HTTP.post(
                _oidcuri(conn.authuri, conn.realm, "logout"),
                FORMHEADERS,
                URIs.escapeuri(
                    Dict(
                        "client_id" => conn.clientid,
                        "refresh_token" => tokens.refreshtoken,
                    ),
                );
                status_exception=false,
            )
        catch ex
            @debug "Logout failed" exception = ex
        end
    end

    # A refresher that already stopped, because the connection dropped, cannot
    # be scheduled again.
    istaskdone(conn.refresher) && return nothing

    schedule(conn.refresher, InterruptException(); error=true)

    return nothing
end

function _qhivecallback(
    req::HTTP.Request,
    authuri::URI,
    realm,
    clientid,
    state,
    redirecturi,
    c::Condition,
)
    params = queryparams(URI(req.target))

    # The state ties the callback to the request that opened the browser, so a
    # forged or replayed one is rejected before the code is spent.
    if get(params, "state", nothing) != state
        notify(
            c,
            ErrorException("The identity provider replied with an unexpected state.");
            error=true,
        )
        return HTTP.Response(400, "Invalid state")
    end

    code = get(params, "code", nothing)

    if isnothing(code)
        notify(
            c,
            ErrorException("The identity provider replied without an authorization code.");
            error=true,
        )
        return HTTP.Response(400, "Missing authorization code")
    end

    local result

    try
        result = _qhivetokens(
            authuri,
            realm,
            clientid,
            Dict(
                "grant_type" => "authorization_code",
                "code" => code,
                "redirect_uri" => redirecturi,
            ),
        )
    catch ex
        notify(c, ex; error=true)
        return HTTP.Response(500, "Failed to obtain a token from the identity provider")
    end

    notify(c, result)

    return HTTP.Response(200, "You may now close this window")
end

function _qhivelogin(authuri::URI, realm, clientid)
    # A cryptographic source: this value is what tells a genuine callback from a
    # forged one.
    state = bytes2hex(rand(RandomDevice(), UInt8, 16))

    logged = Condition()
    redirecturi = Ref("")

    router = HTTP.Router()
    HTTP.register!(
        router,
        "GET",
        "/callback",
        req -> _qhivecallback(req, authuri, realm, clientid, state, redirecturi[], logged),
    )

    server = HTTP.serve!(router, Sockets.localhost, 1444; listenany=true)

    p = HTTP.port(server)
    redirecturi[] = "http://localhost:$(p)/callback"

    url = string(
        URI(
            _oidcuri(authuri, realm, "auth");
            query=Dict(
                "client_id" => clientid,
                "response_type" => "code",
                "scope" => "openid",
                "state" => state,
                "redirect_uri" => redirecturi[],
            ),
        ),
    )

    @info "Please login in your browser at $url"
    open_in_default_browser(url)

    try
        return wait(logged)
    finally
        close(server)
    end
end

_qhiveauthuri(uri::URI, ::Nothing) = joinpath(uri, "auth")
_qhiveauthuri(::URI, authurl) = _url_to_uri(authurl)

"""
    connect(QhiveConnection[; url, authurl, realm, clientid])
    connect(QhiveConnection, token[; url, authurl, realm, clientid])
    connect(QhiveConnection, email, password[; url, authurl, realm, clientid])

Establish a connection to the Quantum Hive Services.

Authentication goes through Keycloak. The first method opens a login page in the
default browser, the second reuses a refresh token obtained earlier, and the
third signs in directly with an email and a password.

A refresh process is spawned in the background to refresh the access token
before it expires. Close the connection with `close(connection)`, which also
ends the session on the identity provider.

## Keyword arguments

* `url`: the URI of the Quantum Hive services (default: `QPERFECT_DEV`)
* `authurl`: the URI of the identity provider (default: `url` with `/auth`)
* `realm`: the Keycloak realm (default: `QHIVE_REALM`)
* `clientid`: the Keycloak client (default: `QHIVE_CLIENT_ID`)

## Examples

```julia
julia> connection = connect(QhiveConnection)

julia> close(connection)
```

!!! warning
    The third method is discouraged, as it leaves your password in plain text in
    scripts and notebooks.
"""
function connect(
    ::Type{QhiveConnection};
    url=QPERFECT_DEV,
    authurl=nothing,
    realm=QHIVE_REALM,
    clientid=QHIVE_CLIENT_ID,
)
    uri = _url_to_uri(url)
    authuri = _qhiveauthuri(uri, authurl)

    tokens, expiresin = _qhivelogin(authuri, realm, clientid)

    return QhiveConnection(uri, authuri, tokens, expiresin; realm, clientid)
end

function connect(
    ::Type{QhiveConnection},
    token::AbstractString;
    url=QPERFECT_DEV,
    authurl=nothing,
    realm=QHIVE_REALM,
    clientid=QHIVE_CLIENT_ID,
)
    uri = _url_to_uri(url)
    authuri = _qhiveauthuri(uri, authurl)

    @info "Obtaining access token for connection"
    tokens, expiresin = _qhiverefresh(authuri, realm, clientid, Tokens("", token))

    return QhiveConnection(uri, authuri, tokens, expiresin; realm, clientid)
end

function connect(
    ::Type{QhiveConnection},
    email::AbstractString,
    password::AbstractString;
    url=QPERFECT_DEV,
    authurl=nothing,
    realm=QHIVE_REALM,
    clientid=QHIVE_CLIENT_ID,
)
    uri = _url_to_uri(url)
    authuri = _qhiveauthuri(uri, authurl)

    @warn "This connection method is discouraged. Please use `connect(QhiveConnection)`, if possible."

    tokens, expiresin = _qhivetokens(
        authuri,
        realm,
        clientid,
        Dict("grant_type" => "password", "username" => email, "password" => password),
    )

    return QhiveConnection(uri, authuri, tokens, expiresin; realm, clientid)
end

"""
    _qhiveuploads(files)

Split the uploads of a request into the form fields the API expects and the
circuit files it wants uploaded one by one.

Returns the form fields as `name => value` pairs and the circuits as
`filename => path` pairs.
"""
function _qhiveuploads(files)
    fields = Pair{String, Any}[]
    circuits = Pair{String, String}[]

    for file in files
        if !(file isa AbstractString)
            throw(
                ArgumentError(
                    "Quantum Hive uploads must be file paths, since the server names every file it stores.",
                ),
            )
        end

        filename = basename(file)
        field = get(QHIVE_FORM_FILES, filename, nothing)

        if isnothing(field)
            push!(circuits, filename => file)
        else
            push!(fields, field => file)
        end
    end

    return fields, circuits
end

function request(
    conn::QhiveConnection,
    emulatortype::AbstractString,
    name::AbstractString,
    label::AbstractString,
    timeout::Integer,
    files...,
)
    if timeout <= 0
        throw(ArgumentError("Timeout must be a positive integer"))
    end

    fields, circuits = _qhiveuploads(files)

    data = Pair{String, Any}[
        "algorithm" => name,
        "label" => label,
        "emuType" => emulatortype,
        "timeout" => string(timeout),
    ]

    for (field, path) in fields
        push!(data, field => open(path, "r"))
    end

    res = HTTP.post(
        geturi(conn, "jobs"),
        [authheader(conn)],
        HTTP.Form(data);
        status_exception=false,
    )

    _checkresponse(res, "Error creating execution request")

    id = String(strip(String(HTTP.payload(res))))

    # A job is only queued once every circuit is in place and the request is
    # committed, so a failure here leaves nothing running behind.
    for (filename, path) in circuits
        res = HTTP.post(
            geturi(conn, "files", id, "circuit", filename),
            [authheader(conn)],
            read(path);
            status_exception=false,
        )
        _checkresponse(res, "Error uploading $(filename)")
    end

    res = HTTP.patch(
        geturi(conn, "jobs", id, "commit"),
        [authheader(conn)],
        "";
        status_exception=false,
    )

    _checkresponse(res, "Error committing execution request")

    return Execution(id)
end

function requestinfo(conn::QhiveConnection, req::Execution)
    res = HTTP.get(
        geturi(conn, "jobs", req.id),
        [authheader(conn)],
        "";
        status_exception=false,
    )

    _checkresponse(res, "Error retrieving execution information")

    return JSON.parse(String(HTTP.payload(res)))
end

function requests(conn::QhiveConnection; kwargs...)
    uri = URI(geturi(conn, "jobs"); query=Dict(kwargs...))

    res = HTTP.get(uri, [authheader(conn)], ""; status_exception=false)

    _checkresponse(res, "Error retrieving requests")

    return JSON.parse(String(HTTP.payload(res)))
end

_qhivestatus(conn::QhiveConnection, req::Execution) =
    get(requestinfo(conn, req), "status", "")

isjobdone(conn::QhiveConnection, req::Execution) =
    _qhivestatus(conn, req) in QHIVE_DONE_STATUSES

isjobfailed(conn::QhiveConnection, req::Execution) = _qhivestatus(conn, req) == "ERROR"

isjobstarted(conn::QhiveConnection, req::Execution) =
    _qhivestatus(conn, req) in QHIVE_STARTED_STATUSES

isjobcanceled(conn::QhiveConnection, req::Execution) = _qhivestatus(conn, req) == "CANCELED"

function stopexecution(conn::QhiveConnection, req::Execution)
    res = HTTP.patch(
        geturi(conn, "jobs", req.id, "cancel"),
        [authheader(conn)],
        "";
        status_exception=false,
    )

    _checkresponse(res, "Error stopping execution")

    return true
end

function deletefiles(conn::QhiveConnection, req::Execution)
    res = HTTP.delete(
        geturi(conn, "files", req.id),
        [authheader(conn)],
        "";
        status_exception=false,
    )

    # The API answers 200 while the job is still running, and 202 once the files
    # are scheduled for deletion.
    if res.status == 200
        error("Error deleting files: the job has not completed yet.")
    end

    _checkresponse(res, "Error deleting files")

    return true
end

function _downloadfiles(conn::QhiveConnection, req::Execution, destdir, type)
    @debug "Downloading jobfiles in $destdir"

    source = QHIVE_FILE_SOURCES[type]

    res = HTTP.get(
        geturi(conn, "files", req.id, source),
        [authheader(conn)],
        "";
        status_exception=false,
    )

    _checkresponse(res, "Error retrieving files")

    urls = JSON.parse(String(HTTP.payload(res)))

    if isempty(urls)
        @warn "No files to download."
        return String[]
    end

    if !isdir(destdir)
        mkpath(destdir)
    end

    # The API answers with pre-signed links, which carry their own credentials
    # and reject the connection header.
    return String[_download(url, destdir; update_period=Inf) for url in urls]
end
