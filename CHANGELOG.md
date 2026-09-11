# Changelog

All notable changes to `MimiqLink.jl` are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

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
