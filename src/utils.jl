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

_url_to_uri(url::AbstractString) = URI(url)
_url_to_uri(url::URI) = url

function _checkresponse(res::HTTP.Response, prefix="Error")
    if res.status < 300
        return nothing
    end

    if isempty(HTTP.payload(res))
        error("$prefix: Server responded with code $(res.status).")
    end

    json = JSON.parse(String(HTTP.payload(res)))

    if haskey(json, "message")
        message = json["message"]
        error(lazy"$(prefix): $(message)")
    else
        error(lazy"$prefix: Server responded with code $(res.status).")
    end

    return nothing
end
