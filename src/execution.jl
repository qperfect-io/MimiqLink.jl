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
