# Changelog

All notable changes to `MimiqLink.jl` are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.11.1] — 2026-09-27

### Added

- `requests`, `printrequests`, `stopexecution` and `deletefiles` are exported.
  They were documented as part of the interface and reached for by name
  downstream, but had to be qualified as `MimiqLink.stopexecution` to be used.

### Fixed

- The `connect` docstring example opens with a `jldoctest` fence instead of
  the misspelled `jldoctests`, which made Documenter 1.18+ abort the docs build
  of any package including MimiqLink's docstrings.
- A connection whose refresh fails now reports it. The refresher read its token
  channel with `fetch`, which leaves the channel full, then tried to `put!` an
  empty token into it: the task blocked there forever, the error was never
  logged and the connection looked open for the rest of the session.
- `close` on a connection whose refresher already stopped no longer throws.

### Build

- Every dependency now carries a compat bound closing at the version it is
  allowed to break in. `HTTP` in particular was unbounded, so a fresh install
  could resolve 2.0 and leave `connect()` throwing a `MethodError` from
  `HTTP.serve!` on the login page.

### Tooling

- The test suite drives the client against local stand-ins for the MIMIQ and
  Quantum Hive APIs — real HTTP servers on a free port — covering
  authentication, token rotation, the job lifecycle, downloads and the failure
  paths. No credentials, and nothing leaves the machine.
- GitLab CI runs the suite on Julia 1.11 and on the current stable release, and
  checks the formatting against `.JuliaFormatter.toml`.

## [0.11.0] — 2026-09-11

### Added

- `QhiveConnection` connects to the Quantum Hive web services, authenticating
  through Keycloak with a browser login, an email and a password, or a refresh
  token obtained earlier. It mirrors the Python `QhiveConnection`.

### CI
- The GitLab `register` job now fires only on `-private` tags. The
  bare public `vX.Y.Z` tag is registered into QPerfectRegistry by
  the GitHub Actions workflow on the public remote; the previous
  rule attempted both and could double-register.

## [0.10.7]

Changelog tracking begins with this version. See git history for prior changes.
