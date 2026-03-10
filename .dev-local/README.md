# Local Workspace Notes

This folder is intentionally used for local, non-release artifacts:

- smoke/e2e scripts and their logs
- temporary configs used during debugging
- archives and production snapshots copied for migration checks

Git policy:

- everything in `.dev-local` is ignored by default
- only this file is kept in Git for team context

Future reminders:

1. Before release validation, run:
   - `romitter.exe -t -p <prefix> -c <nginx.conf>`
   - `romitter.exe -s reload -p <prefix> -c <nginx.conf>`
   - HTTP health checks before and after reload with `Connection: close`
   - stream TCP/UDP payload e2e checks against real backends
2. Keep production snapshots and generated configs only here, not in source folders.
3. If a new migration issue appears, store repro configs and logs under `.dev-local/smoke/<date>-<topic>/`.

