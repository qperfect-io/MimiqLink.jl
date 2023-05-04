# This code is based on HTTP.jl v1.7.4
# https://github.com/JuliaWeb/HTTP.jl/blob/040df996e608572fee760fc9816376a2d8fe3299/src/download.jl#L79-L95
#
# Copyright (c) 2022: https://github.com/JuliaWeb/HTTP.jl/graphs/contributors.
# The HTTP.jl package is licensed under the MIT "Expat" License:
# https://github.com/JuliaWeb/HTTP.jl/blob/master/LICENSE.md
#
# similar to HTTP.download, but instead of using the callback to report
# progress, use ProgressLogging.jl
function _download(url::AbstractString, local_path=nothing, headers=HTTP.Header[]; kw...)
    # code taken and modified from HTTP.jl v1.7.4

    @debug "Downloading $url"

    # NOTE: defined here to be persistent through all redirections
    local file
    hdrs = String[]

    # automatically takes care of redirections
    HTTP.open("GET", url, headers; kw...) do stream
        resp = startread(stream)
        # Store intermediate header from redirects to use for filename detection
        content_disp = HTTP.header(resp, "Content-Disposition")
        !isempty(content_disp) && push!(hdrs, content_disp)
        eof(stream) && return  # don't do anything for streams we can't read (yet)

        file = HTTP.determine_file(local_path, resp, [content_disp])
        total_bytes = parse(Float64, HTTP.header(resp, "Content-Length", "NaN"))
        downloaded_bytes = 0

        if HTTP.header(resp, "Content-Encoding") == "gzip"
            stream = HTTP.GzipDecompressorStream(stream) # auto decoding
            total_bytes = NaN # We don't know actual total bytes if the content is zipped.
        end

        # Download the file while loggin progress. In order to show progress bars
        # an user should install and configure TerminalLoggers.jl
        @withprogress name = basename(file) begin
            Base.open(file, "w") do fh
                while (!eof(stream))
                    downloaded_bytes += write(fh, readavailable(stream))
                    @logprogress downloaded_bytes / total_bytes
                end
            end
        end
    end

    file
end
