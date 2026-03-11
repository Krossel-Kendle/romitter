# romitter

`romitter` is a Windows-native, Delphi-based nginx analog focused on:

- high nginx configuration compatibility
- drop-in operations for common nginx workflows
- practical Windows-first behavior for proxy workloads

## Versioning and Release Notes

`romitter` uses semantic-style versioning with pre-release tags (`major.minor.patch-label`).

- Current: `0.1.2-alpha`
- Previous: `0.1.1-alpha`

### Fix Pool: 0.1.2-alpha vs 0.1.1-alpha

- Added server-side HTTP/2 runtime path for TLS listeners with `listen ... ssl http2`.
- Added ALPN negotiation (`h2` / `http/1.1`) during TLS handshake.
- Added HTTP/2 frame handling:
  - `SETTINGS`, `HEADERS`, `CONTINUATION`, `DATA`, `WINDOW_UPDATE`, `PING`, `RST_STREAM`, `GOAWAY`.
- Added HPACK decoder/encoder runtime components:
  - indexed/literal header representations
  - dynamic table updates
  - Huffman decode support for request header blocks
- Added HTTP/2 stream state handling for request/response lifecycle.
- Added HTTP/2-to-existing HTTP runtime bridge so existing location/proxy/file logic is reused for h2 streams.
- Added `nginx.conf`-style TLS listener ALPN setup via OpenSSL runtime bindings.

### Fix Pool: 0.1.1-alpha vs 0.1.0-alpha

- Added runtime support for `proxy_protocol` on HTTP listeners (`listen ... proxy_protocol`).
- Added runtime support for `proxy_protocol` on stream TCP listeners.
- Added parser support for stream `listen ... proxy_protocol`.
- Added `listen ... http2` runtime compatibility path (directive is accepted at runtime; HTTP/2 frame engine remains iterative work).
- Added conflict checks for mixed endpoint options:
  - `proxy_protocol` and non-`proxy_protocol` cannot share one listen endpoint.
- Added top-level nginx directives:
  - `master_process on|off`
  - `daemon on|off`
- Runtime now honors `master_process off` (single-process mode).
- Reduced startup/runtime log noise in high-worker deployments:
  - shared listener reuse messages
  - repetitive listener startup messages
  - repeated control pipe busy retries
  - noisy TLS client-alert handshake logs

## Why romitter on Windows

Official nginx on Windows is intentionally limited. `romitter` is designed to close that gap and support Windows-specific production use cases, including scenarios that are often unavailable or constrained in standard Windows nginx deployments, for example:

- stream proxying for TCP **and UDP** ports
- nginx-style runtime control commands (`-t`, `-s reload|quit|stop`)
- multi-worker process model with graceful lifecycle handling

## nginx Compatibility

`romitter` aims to be nginx-compatible by configuration and operations:

- nginx syntax and context model (`events`, `http`, `stream`, `server`, `location`, `upstream`, `include`)
- nginx-like directive inheritance in `http/server/location` and `stream/server`
- nginx CLI-style control flow:
  - `romitter -t ...`
  - `romitter -s reload ...`
  - `romitter -s quit ...`
  - `romitter -s stop ...`

For typical reverse-proxy and stream (TCP/UDP) scenarios, existing nginx configs can be reused with minimal or no changes. Unsupported directives fail fast during config validation instead of being silently ignored.

## Binary Name Compatibility

You can rename `romitter.exe` to `nginx.exe`.

For standard automation patterns (including wrappers that call `nginx -t` and `nginx -s reload` with `-p/-c`), this works as a practical drop-in approach.

## Feature Highlights

- HTTP reverse proxy with upstream balancing and retries
- streaming request body mode (`proxy_request_buffering off`)
- chunked request decoding + `Expect: 100-continue`
- stream module for TCP and UDP proxy
- TLS termination (OpenSSL runtime), SNI routing, per-server certificates
- static file serving, rewrites, `try_files`, `error_page`, `allow`/`deny`
- fast config test and runtime reload

## Quick Start

1. Build `romitter.dpr` for Win64.
2. Ensure OpenSSL DLLs are available near the executable (`libssl` + `libcrypto`).
3. Run:

```powershell
.\Win64\Release\romitter.exe -c conf\romitter.conf
```

4. Validate config:

```powershell
.\Win64\Release\romitter.exe -t -c conf\romitter.conf
```

## Command Line

```text
romitter [-c file] [-p prefix]
romitter -t [-c file] [-p prefix]
romitter -T [-c file] [-p prefix]
romitter -s signal [-c file] [-p prefix]
romitter -v
```

Signals:

- `stop` = fast shutdown
- `quit` = graceful shutdown
- `reload` = config reload

## Example Configs

Ready-to-run example configs are provided under:

- `conf/examples/`

They cover:

- minimal HTTP setup
- reverse-proxy setup
- stream TCP/UDP setup
- full showcase config with includes for generated `http` and `stream` blocks

## Repository Layout

- `src/` - Delphi source code
- `conf/` - config files and examples
- `nginx/src/` - nginx source snapshot used for compatibility reference

## License

This project is distributed under a BSD-2-Clause style permissive license (see `LICENSE`), allowing free commercial and non-commercial use.
