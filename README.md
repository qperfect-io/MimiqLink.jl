# MIMIQ Link (`MimiqLink.jl`)

This library allow for communication between local scripts and notebooks and remote MIMIQ instances.

# Usage

```
julia> using MimiqLink

julia> mimiqserver = MimiqLink.connect("http://vps-f8c698f6.vps.ovh.net/")
...

julia> job = MimiqLink.request(mimiqserver, "a name", "a label", "filename1", "filename2", open("filename3"))
...

julia> getrequestinfo(mimiqserver, job)
...

julia> close(mimiqserver)
...
```
# COPYRIGHT

Copyright © 2022-2023 University of Strasbourg. All Rights Reserved.

# AUTHORS

See [AUTHORS.md](AUTHORS.md) for the list of authors.
