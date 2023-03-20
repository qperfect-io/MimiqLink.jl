# MIMIQ Link (`MimiqLink.jl`)

This library allow for communication between local scripts and notebooks and
remote MIMIQ instances.

It allows for three different connection modes: via login page, via token, via
credentials.

## Login Page

This method will open a browser pointing to a login page. The user will be
asked to insert username/email and password.

```
julia> using MimiqLink

julia> connection = MimiqLink.connect()
```

Optionally an address for the MIMIQ services can be specified

```
julia> connection = MimiqLink.connect(uri = "http://127.0.0.1/api")
```

## Token

This method will allow the user to save a token file (by login via a login
page), and then load it also from another Julia session.

```
julia> using MimiqLink

julia> MimiqLink.savetoken(uri = "http://127.0.0.1/api")
```

this will save a token in the `qperfect.json` file in the current directory.
In another Julia session is then possible to do:

```
julia> using MimiqLink

julia> connection = MimiqLink.loadtoken("path/to/my/qperfect.json")
```

## Credentials

This method will allow users to access by directly use their own credentials.

**WARNING** it is strongly discuraged to use this method. If files with
credentials will be shared the access to the qperfect account might be
compromised.

```
julia> using MimiqLink

julia> connection = MimiqLink.connect("me@mymail.com", "myweakpassword")
```

```
julia> MimiqLink.connect("me@mymail.com", "myweakpassword"; uri = "http://127.0.0.1/api")
```
# COPYRIGHT

Copyright © 2022-2023 University of Strasbourg. All Rights Reserved.

# AUTHORS

See [AUTHORS.md](AUTHORS.md) for the list of authors.
