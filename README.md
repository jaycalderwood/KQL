# KQL Library (Combined: Non-Scoped + Resource-Scoped)

This repository contains a comprehensive KQL library for Azure/M365, **plus** a `ResourceScoped/` duplicate for every `.kql` that adds optional filtering by Azure resource (ResourceId, Name, Type, RG, Subscription, Location).

**Generated:** 20250826_121742

- Use **Run-KQL-Library.ps1** to run:
  1. Normal Log Analytics/Sentinel queries (pick/search)
  2. Microsoft 365 Defender Advanced Hunting (Graph)
  3. Azure Resource Graph `.arg`
  4. **Resource-Scoped** KQL: pick a resource first, runner auto-fills tokens in `*.resource.kql`

## Structure
- `KQL-Library/<Pack>/*.kql` – normal queries
- `KQL-Library/<Pack>/ResourceScoped/*.resource.kql` – resource-scoped variants
- `Run-KQL-Library.ps1` – interactive runner
- `Pull-Library.ps1` – update/pull script (git or zip)
- `LICENSE` – MIT
- `README.md` / `README.html`
- `.gitignore`
- `PacksIndex.json`
