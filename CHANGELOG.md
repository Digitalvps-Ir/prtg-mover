# Changelog

## 1.0.0 — 2026-09-28

### Added
- Web dashboard (`Start-PrtgMover.ps1`) with servers, backup & migrate, backups (download / upload / restore) and live jobs.
- Full PRTG migration: data folder, registry, SSL certificate, custom sensors, notifications, lookups, MIBs, device templates, map objects.
- Windows VPN (RAS phonebook) export and non-destructive merge on the target.
- Desktop files of all user profiles and the Public desktop.
- Extra file and folder paths.
- Silent PRTG installation on targets without PRTG, version check, rollback copy, automatic start and web health check.
- One source to many targets in a single job.
- DPAPI-encrypted credential store and a token-protected dashboard.
- CLI (`cli/Invoke-PrtgMover.ps1`) with retention for scheduled backups.
- Server preparation scripts for the manager and for servers.
- Pester 5 test suite and GitHub Actions CI.
