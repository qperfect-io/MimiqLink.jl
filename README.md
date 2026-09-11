<p align="center">
  <img src="logo.svg" alt="MIMIQ" width="380">
</p>

# MimiqLink.jl

[![Build Status](https://github.com/qperfect-io/MimiqLink.jl/workflows/CI/badge.svg)](https://github.com/qperfect-io/MimiqLink.jl/actions)
[![Documentation](https://img.shields.io/badge/docs-stable-blue.svg)](https://docs.qperfect.io/MimiqCircuits.jl/stable/)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

**MimiqLink.jl** provides secure authentication and connection management for QPerfect's MIMIQ Virtual Quantum Computer. It handles all communication between local Julia environments and MIMIQ's remote execution services.

Part of the [MIMIQ](https://qperfect.io) ecosystem by [QPerfect](https://qperfect.io).

## Overview

MimiqLink offers flexible authentication methods to connect to MIMIQ's cloud services:

- 🌐 **Browser-based login**
- 🔑 **Token-based access** - Save and reuse authentication tokens
- 🔐 **Credential-based login** - Direct username/password authentication
- 🔄 **Session management** - Automatic token refresh and connection handling
- 🏢 **Multi-environment support** - Connect to different MIMIQ instances

## Installation

Add the QPerfect registry first:

```julia
using Pkg
Pkg.Registry.add("General")
Pkg.Registry.add(RegistrySpec(url="https://github.com/qperfect-io/QPerfectRegistry.git"))
```

Then install MimiqLink:

```julia
Pkg.add("MimiqLink")
```

> **Note:** Most users should install [MimiqCircuits.jl](https://github.com/qperfect-io/MimiqCircuits.jl) which includes this package and provides the full MIMIQ experience.

## Quick Start

### Method 1: Browser-Based Login (Recommended)

This method opens a login page in your browser for secure authentication:

```julia
using MimiqLink

# Connect using browser login
connection = MimiqLink.connect()
```

This will:

1. Open your default browser
2. Direct you to the MIMIQ login page
3. Securely authenticate your session
4. Return a connection object

### Method 2: Token-Based Access

Save your authentication token for reuse across sessions:

```julia
using MimiqLink

# First time: Save your token
MimiqLink.savetoken()  # Opens browser for authentication
```

This saves a token to `qperfect.json` in your current directory.

In future sessions:

```julia
using MimiqLink

# Load saved token
connection = MimiqLink.loadtoken("qperfect.json")

# Or load from a specific path
connection = MimiqLink.loadtoken("/path/to/my/qperfect.json")
```

### Method 3: Direct Credentials

⚠️ **Warning:** This method is less secure as credentials may be exposed in scripts or logs.

```julia
using MimiqLink

# Connect with credentials directly
connection = MimiqLink.connect("your.email@example.com", "yourpassword")
```

## Connecting to Different MIMIQ Instances

By default, MimiqLink connects to the production MIMIQ service. You can specify alternative instances:

```julia
using MimiqLink

# Connect to a custom MIMIQ instance
connection = MimiqLink.connect(uri = "http://localhost:8080/api")

# Save token for a custom instance
MimiqLink.savetoken(uri = "http://custom-mimiq.example.com/api")

# Load token with custom instance
connection = MimiqLink.loadtoken("token.json", uri = "http://custom-mimiq.example.com/api")
```

## Usage with MimiqCircuits

MimiqLink is typically used through the MimiqCircuits package:

```julia
using MimiqCircuits

# The connect() function from MimiqCircuits uses MimiqLink internally
conn = connect()

# Now use the connection to execute circuits
c = Circuit()
push!(c, GateH(), 1)
push!(c, GateCX(), 1, 2)
push!(c, Measure(), 1:2, 1:2)

job = execute(conn, c; nsamples=1000)
results = getresults(conn, job)
```

## Connection Object

The connection object returned by MimiqLink contains:

- Authentication credentials
- API endpoint information
- Session state

You can check your connection status:

```julia
connection = MimiqLink.connect()
println("Connected to: ", connection.uri)
```

## Security Best Practices

1. **Use browser-based login** when possible for maximum security
2. **Protect token files** - treat `qperfect.json` like a password
3. **Never commit credentials** to version control
4. **Use environment variables** for automated systems:

```julia
using MimiqLink

# Get credentials from environment variables
email = ENV["MIMIQ_EMAIL"]
password = ENV["MIMIQ_PASSWORD"]
connection = MimiqLink.connect(email, password)
```

5. **Rotate tokens regularly** by re-running `savetoken()`

## Troubleshooting

### Browser doesn't open

If the browser doesn't open automatically:

```julia
# Manually copy the URL that appears in the console
# and paste it into your browser
```

### Connection timeout

```julia
# Specify a longer timeout (in seconds)
connection = MimiqLink.connect(timeout = 60)
```

### Token expired

If your token has expired, simply create a new one:

```julia
MimiqLink.savetoken()  # This will create a fresh token
```

### Custom certificate validation

For self-hosted MIMIQ instances with custom certificates:

```julia
connection = MimiqLink.connect(uri = "https://custom-mimiq.example.com/api")
```

## API Reference

### Main Functions

- `connect()` - Establish connection using browser login
- `connect(email, password)` - Connect using credentials
- `savetoken([path])` - Save authentication token to file
- `loadtoken(path)` - Load authentication token from file
- `close(connection)` - Close connection and invalidate session

### Connection Options

- `uri` - MIMIQ service endpoint URL

## Related Packages

- **[MimiqCircuits.jl](https://github.com/qperfect-io/MimiqCircuits.jl)** - Main package for building and executing quantum circuits (includes this package)
- **[MimiqCircuitsBase.jl](https://github.com/qperfect-io/MimiqCircuitsBase.jl)** - Core circuit building functionality
- **[mimiqlink-python](https://github.com/qperfect-io/mimiqlink-python)** - Python equivalent of this library

## Access to MIMIQ

To use MIMIQ's remote services, you need an active subscription:

- 🌐 **[Register for MIMIQ](https://qperfect.io)** to get started
- 📧 Contact us at <contact@qperfect.io> for organizational subscriptions
- 🏢 If your organization has a subscription, contact your account administrator

## Contributing

We welcome contributions! Please feel free to:

- 🐛 Report bugs
- 💡 Suggest features
- 📝 Improve documentation
- 🔧 Submit pull requests

## Support

- 📧 Email: <mimiq.support@qperfect.io>
- 🐛 Issues: [GitHub Issues](https://github.com/qperfect-io/MimiqLink.jl/issues)
- 💬 Discussions: [GitHub Discussions](https://github.com/qperfect-io/MimiqCircuits.jl/discussions)

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
