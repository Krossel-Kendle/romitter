# Configuration Examples

This folder contains nginx-compatible configuration examples for `romitter`.

## Files

- `nginx.minimal.conf`  
  Small HTTP-only setup (static + health endpoint).

- `nginx.reverse-proxy.conf`  
  HTTP upstream balancing, retries, buffering, and request streaming mode.

- `nginx.stream.tcp-udp.conf`  
  Stream module examples for TCP and UDP proxying.

- `nginx.full.conf`  
  Full showcase configuration using generated include folders (`conf.d/http.generated` and `conf.d/stream.generated`).

## Optional include content

- `conf.d/http.generated/*.conf`
- `conf.d/stream.generated/*.conf`

These are sample fragments intended to mimic production generators (for example, external config management or API-driven vhost provisioning).

## Validation

From repository root:

```powershell
.\Win64\Release\romitter.exe -t -p conf\examples -c conf\examples\nginx.full.conf
```

