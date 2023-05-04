# MimiqLink.jl

This library allow for communication between local scripts and notebooks and
remote MIMIQ instances.

## Usage

**MimiqLink** allows for three different connection modes: via login page, via token, via
credentials.

### Login Page

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

### Credentials

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

## COPYRIGHT

Copyright © 2022-2023 University of Strasbourg. All Rights Reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

