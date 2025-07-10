#
# Copyright © 2022-2024 University of Strasbourg. All Rights Reserved.
# Copyright © 2023-2025 QPerfect. All Rights Reserved.
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

"""
    module MimiqLink end

This module contains convenience tools to establish and keep up a connection
to the QPerfect MIMIQ services, both remote or on premises.

It allows for three different connection modes: via login page, via token, via
credentials.

## Login Page

This method will open a browser pointing to a login page. The user will be asked
to insert username/email and password.

```
julia> using MimiqLink

julia> connection = MimiqLink.connect()
```

optionally an address for the MIMIQ services can be specified

```
julia> connection = MimiqLink.connect(url = "http://127.0.0.1")
```

## Token

This method will allow the user to save a token file (by login via a login
page), and then load it also from another julia session.

```
julia> using MimiqLink

julia> MimiqLink.savetoken(url = "http://127.0.0.1")
```

this will save a token in the `qperfect.json` file in the current directory.
In another julia session is then possible to do:

```
julia> using MimiqLink

julia> connection = MimiqLink.loadtoken("path/to/my/qperfect.json")
```

## Credentials

This method will allow users to access by directly use their own credentials.

!!! warning
    It is strongly discuraged to use this method. If files with credentials will
    be shared the access to the qperfect account might be compromised.

```
julia> using MimiqLink

julia> connection = MimiqLink.connect("me@mymail.com", "myweakpassword")
```

```
julia> MimiqLink.connect("me@mymail.com", "myweakpassword"; url = "http://127.0.0.1")
```
"""
module MimiqLink

using DotEnv
using FileTypes
using HTTP
using Sockets
using JSON
using URIs
using ProgressLogging

export connect
export loadtoken
export savetoken
export request
export requestinfo
export isjobdone
export isjobfailed
export isjobstarted
export isjobcanceled
export downloadresults
export downloadjobfiles
export QPERFECT_CLOUD
export QPERFECT_DEV

export AbstractConnection
export MimiqConnection
export PlanqkConnection
export Execution

# How does the library works?
# When using connect() the library will spawn a little file server that will serve the files contained in the /public folder.
# A browser page will open showing the served login page
# The user can insert its username and password.
# After receiving the username and password the server will try to login at the remote endpoint.
# If login is successfull it will store the received token and spawn a process that will refresh the token every 15 minutes
# A Connection object will contain all the information required to send requests with the request(...) function.
# The user can close the connection, shutting down the automatic refresher, by using the close(...) function.

"""
    abstract type AbstractConnection

Abstract type for the connection to the MIMIQ Services.
"""
abstract type AbstractConnection end

include("utils.jl")

"""
   const QPERFECT_CLOUD

Address for the QPerfect Cloud services
"""
const QPERFECT_CLOUD = URI("https://mimiq.qperfect.io")

"""
   const QPERFECT_DEV

Address for secondary QPerfect Cloud services
"""
const QPERFECT_DEV = URI("https://mimiqfast.qperfect.io")

"""
  const DEFAULT_INTERVAL

Default refresh interval for tokens (in seconds)
"""
const DEFAULT_INTERVAL = 15 * 60

# headers to have request send json content
const JSONHEADERS = ["Content-Type" => "application/json"]

# include _download function (taken and modified from HTTP.jl to allow progress reporting)
include("download.jl")

# MimiqConnection type
include("mimiq.jl")

# PlanqkConnection type
include("planqk.jl")

# Execution type
include("execution.jl")

"""
    geturi(connection_type, uri)
    geturi(connection)
    geturi(connection, parts...)

Get the URI for API calls through a specific connection or service.
"""
function geturi end

"""
    connect([; url=QPREFECT_CLOUD])
    connect(token[; url=QPREFECT_CLOUD])
    connect(username, password[; url=QPREFECT_CLOUD])

    connect(PlanqkConnection, url, consumer_key, consumer_secret)
    connect(PlanqkConnection)

Establish a connection to the MIMIQ Services.

The first three methods return a [`MimiqConnection`](@ref).

The last method return a [`PlanqkConnection`](@ref) effectively connecting through
[PlanQK](https://platform.planqk.de).

A refresh process will be spawned in the background to refresh the access credentials.
An active connection can be closed by using the `close(connection)` method. As an example:

```julia
connection = connect("john.doe@example.com", "johnspassword")
# connecton will be of type MimiqConnection
close(connection)
```

!!! warning

    The first method will open a login page in the default browser and ask for
    your email and password. This method is encouraged, as it will avoid saving
    your password as plain text in your scripts or notebooks.

There are two main servers for the MIMIQ Services: the main one and a secondary one.
Users are supposed to use the main one.

```jldoctests
julia> QPERFECT_CLOUD
URI("https://mimiq.qperfect.io")

julia> QPERFECT_DEV
URI("https://mimiqfast.qperfect.io")
```
"""
function connect end

# TODO: add support for progress bars when uploading files
function request(
    conn::AbstractConnection,
    emulatortype::AbstractString,
    name::AbstractString,
    label::AbstractString,
    timeout::Integer,
    files...,
)
    if timeout <= 0
        throw(ArgumentError("Timeout must be a positive integer"))
    end

    data = Pair{String, Any}[
        "name" => name,
        "label" => label,
        "emulatorType" => emulatortype,
        "timeout" => string(timeout),
    ]

    for file in files
        if file isa AbstractString
            push!(data, "uploads" => open(file, "r"))
        else
            push!(data, "uploads" => file)
        end
    end

    body = HTTP.Form(data)

    res =
        HTTP.post(geturi(conn, "request"), [authheader(conn)], body; status_exception=false)

    _checkresponse(res, "Error creating execution request")

    res = JSON.parse(String(HTTP.payload(res)))
    return Execution(res["executionRequestId"])
end

"""
    stopexecution(conn, req)

Stop the execution of a request.
"""
function stopexecution(conn::AbstractConnection, req::Execution)
    uri = geturi(conn, "stop-execution", req.id)
    res = HTTP.post(uri, [authheader(conn)], ""; status_exception=false)
    _checkresponse(res, "Error stopping execution")
    return true
end

"""
    deletefiles(conn, req)"

Delete the files associated with a request.
"""
function deletefiles(conn::AbstractConnection, req::Execution)
    uri = geturi(conn, "delete-files", req.id)
    res = HTTP.post(uri, [authheader(conn)], ""; status_exception=false)
    _checkresponse(res, "Error deleting files")
    return true
end

"""
    requests(conn; kwargs...)

Retrieve the list of requests on the MIMIQ Cloud Services.

!!! note
    It is only possible to retrieve the requests that the user has permissions
    to see.
    This is often limited to the requests that the user has created, for normal
    users, and to all organization requests, for organization administrators.

## Keyword arguments

* `status`: filter by status. Can be `NEW`, `RUNNING`, `ERROR`, `CANCELED`, `DONE`.
* `userEmail`: filter by user email.
* `limit`: limit the number of requests to retrieve. Can be [10, 50, 100, 200].
* `page`: page number to retrieve.
"""
function requests(conn::AbstractConnection; kwargs...)
    uri = URI(geturi(conn, "request"); query=Dict(kwargs...))
    res = HTTP.get(uri, [authheader(conn)], ""; status_exception=false)
    _checkresponse(res, "Error retrieving requests")
    res = JSON.parse(String(HTTP.payload(res)))

    return res["executions"]["docs"]
end

"""
    printrequests(conn; kwargs...)

Print the list of requests on the MIMIQ Cloud Services.

## Keyword arguments

* `status`: filter by status. Can be `NEW`, `RUNNING`, `ERROR`, `CANCELED`, `DONE`.
* `userEmail`: filter by user email.
* `limit`: limit the number of requests to retrieve. Can be [10, 50, 100, 200].
* `page`: page number to retrieve.
"""
function printrequests(conn::AbstractConnection; kwargs...)
    reqs = requests(conn; kwargs...)

    numrunning = count(x -> x["status"] == "RUNNING", reqs)
    numnew = count(x -> x["status"] == "NEW", reqs)

    println("$(length(reqs)) jobs of which $(numnew) NEW and $(numrunning) RUNNING:")

    for req in reqs[1:(end - 1)]
        println("├── Request $(req["_id"])")
        println("│   ├── Name: $(req["name"])")
        println("│   ├── Label: $(req["label"])")
        println("│   ├── Status: $(req["status"])")
        println("│   ├── User Email: $(req["user"]["email"])")
        println("│   ├── Created Date: $(req["creationDate"])")
        println("│   ├── Running Date: $(get(req, "runningDate", "None"))")
        println("│   └── Done Date: $(get(req, "doneDate", "None"))")
    end

    let req = reqs[end]
        println("└── Request $(req["_id"])")
        println("    ├── Name: $(req["name"])")
        println("    ├── Label: $(req["label"])")
        println("    ├── Status: $(req["status"])")
        println("    ├── User Email: $(req["user"]["email"])")
        println("    ├── Created Date: $(req["creationDate"])")
        println("    ├── Running Date: $(get(req, "runningDate", "None"))")
        println("    └── Done Date: $(get(req, "doneDate", "None"))")
    end
end

"""
    requestinfo(conn, req)

Retrieve information about an execution request.
"""
function requestinfo(conn::AbstractConnection, req::Execution)
    uri = geturi(conn, "request", req.id)

    res = HTTP.get(uri, [authheader(conn)], "")

    _checkresponse(res, "Error retrieving execution information")

    return JSON.parse(String(HTTP.payload(res)))
end

"""
    isjobdone(conn, execution)

Check if a job is done.

Will return `true` if the job finished successfully or with an error and `false` otherwise.
"""
function isjobdone(conn::AbstractConnection, req::Execution)
    infos = requestinfo(conn, req)
    status = infos["status"]
    return status != "NEW" && status != "RUNNING"
end

"""
    isjobfailed(conn, execution)

Check if a job failed.
"""
function isjobfailed(conn::AbstractConnection, req::Execution)
    infos = requestinfo(conn, req)
    return infos["status"] == "ERROR"
end

"""
    isjobstarted(conn, execution)

Check if a job has started executing.
"""
function isjobstarted(conn::AbstractConnection, req::Execution)
    infos = requestinfo(conn, req)
    return infos["status"] != "NEW"
end

"""
    isjobcanceled(conn, execution)

Check if a job has been canceled.
"""
function isjobcanceled(conn::AbstractConnection, req::Execution)
    infos = requestinfo(conn, req)
    return infos["status"] == "CANCELED"
end

function _downloadfiles(conn::AbstractConnection, req, destdir, type)
    @debug "Downloading jobfiles in $destdir"

    if !isdir(destdir)
        mkdir(destdir)
    end

    infos = requestinfo(conn, req)
    names = []

    nf = get(infos, "numberOf$(type == :uploads ? "Uploaded" : "Resulted")Files", 0)

    if nf == 0 || !(nf isa Number)
        @warn "No files to download."
        return names
    end

    for idx in 0:(nf - 1)
        uri = URI(
            geturi(conn, "files", req.id, string(idx));
            query=Dict("source" => string(type)),
        )
        fname = _download(string(uri), destdir, [authheader(conn)]; update_period=Inf)
        push!(names, fname)
    end

    return names
end

function downloadjobfiles(
    conn::AbstractConnection,
    req::Execution,
    destdir=joinpath("./", req.id),
)
    _downloadfiles(conn, req, destdir, :uploads)
end

function downloadresults(
    conn::AbstractConnection,
    req::Execution,
    destdir=joinpath("./", req.id),
)
    _downloadfiles(conn, req, destdir, :results)
end


end # module MimiqLink
