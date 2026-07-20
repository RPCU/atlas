# Atlas Project Guide for AI Agents

## ⚠️ CRITICAL INSTRUCTIONS FOR AI AGENTS

### 1. Commit Policy

**Do NOT commit changes unless explicitly asked by the user.**

- Always preview changes and request confirmation before committing
- Show `git diff` output to the user
- List all files that will be committed
- Draft commit message for user approval

### 2. Documentation Policy

**ALWAYS UPDATE THIS FILE (AGENTS.md) IF YOU MAKE ANY CHANGES TO THE PROJECT**

Whenever you modify the codebase:

- Add/update relevant sections in this AGENTS.md file
- Document new apps, components, versions, or configurations
- Update directory structure if files are added/removed
- Update the "Last Updated" date at the end of this file
- Include changes in the same request when asking for commit permission

---

## Project Overview

**Atlas** is RPCU's GitOps repository for the **production** workload cluster,
built with Flux CD. It is a **single-cluster application repo** — the heavy
platform lifting (cluster provisioning, CNI, storage drivers, Gateway
controller, Vault auth, cert-manager, base ExternalDNS) is delivered by the
**argus** repo (`../argus`, <https://github.com/RPCU/argus.git>) via Sveltos
ClusterProfiles pushed from the mgmt cluster. Atlas layers the actual
applications (a media stack) and the production-cluster-specific glue on top.

### How the cluster is bootstrapped

1. The production cluster is a CAPI/CAPO-provisioned OpenStack workload cluster
   managed from the argus **mgmt** cluster.
2. Sveltos (on mgmt) deploys Cilium, the Flux Operator + FluxInstance, ESO +
   the `vault-backend` ClusterSecretStore, cert-manager + `vault-issuer`,
   Gateway API + kgateway + the internal `https` Gateway
   (`*.production.rpcu.lan`), ExternalDNS (Designate), the Cinder CSI, and
   csi-driver-nfs — all gated by `sveltos.argus.rpcu.io/*: enabled` labels on
   the CAPI `Cluster` CR.
3. The FluxInstance's own sync points at argus (`./infrastructure/fluxcd/operator`,
   GitRepository `flux-system` in ns flux-system).
4. Atlas plugs in via its own `GitRepository` + `Kustomization` CRs
   (`clusters/production/gitrepository.yaml` + `flux-kustomization.yaml`):
   Flux additionally pulls `https://github.com/RPCU/atlas.git` (branch main)
   and reconciles `./clusters/production`.

### Cross-repo coupling with argus (IMPORTANT)

Atlas resources depend on objects that are **NOT defined in this repo**:

| Dependency (argus/Sveltos-owned)                                                | Consumed by (atlas)                                                                                                                                         |
| ------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| GitRepository `flux-system` (the argus repo itself)                             | `crossplane.yaml` + `crossplane-zitadel.yaml` Flux Kustomizations (source argus paths `./infrastructure/crossplane`, `./infrastructure/crossplane-zitadel`) |
| `vault-backend` ClusterSecretStore (Sveltos `vault-auth` add-on)                | every `ExternalSecret`/`PushSecret` in this repo                                                                                                            |
| kgateway controller + GatewayClass + `gwp-static-ip` GatewayParameters          | `infrastructure/kgateway/gateway.yaml` (`https-external` Gateway)                                                                                           |
| Internal `https` Gateway `*.production.rpcu.lan` (Sveltos `gateway-api` add-on) | radarr/prowlarr/qbittorrent HTTPRoutes                                                                                                                      |
| cert-manager install (Sveltos `cert-manager` add-on)                            | `infrastructure/cert-manager/clusterissuer.yaml` (ACME ClusterIssuer)                                                                                       |
| HelmRepository `external-dns` (ns `internal-dns`, argus base)                   | `infrastructure/external-dns/helmrelease.yaml` (Cloudflare instance)                                                                                        |
| StorageClasses: `csi-cinder-sc-delete` (default, RWO) + `ceph-cephfs` (RWX)     | all PVCs (see Storage section)                                                                                                                              |
| Shared Zitadel org/projects (argus openstack overlay owns the platform)         | `clusters/production/crossplane/oidc-*.yaml` (reference org/project by literal external ID)                                                                 |

If something in atlas fails to reconcile, check whether its argus-side
prerequisite (Sveltos add-on label, Vault path, shared Gateway) exists first.

---

## 1. Directory Structure

### Root Level

- `clusters/production/` - The single cluster's configuration (Flux sync root)
- `infrastructure/` - Production-cluster-specific infrastructure glue
- `devenv.nix` / `devenv.yaml` / `devenv.lock` - Development environment
- `.envrc` - Direnv shell environment loader
- `.yamllint` - YAML linting rules
- `renovate.json5` - Renovate dependency-update configuration
- `README.md` - Project overview

### clusters/production/ - Cluster Configuration

Key files (all listed in `kustomization.yaml`, the kustomize build root that
the `atlas` Flux Kustomization reconciles):

- `kustomization.yaml` - Master orchestration file (Flux Kustomizations + the 4 app dirs)
- `gitrepository.yaml` - Flux `GitRepository` `atlas` (`https://github.com/RPCU/atlas.git`, branch main, interval 1m)
- `flux-kustomization.yaml` - Flux `Kustomization` `atlas` → `./clusters/production` (self-reconciling root, interval 10m)
- `cert-manager.yaml` - Flux Kustomization `cert-manager-issuer` → `./infrastructure/cert-manager` (wait: true)
- `kgateway.yaml` - Flux Kustomization `kgateway-external` → `./infrastructure/kgateway` (wait: true)
- `external-dns.yaml` - Flux Kustomization `external-dns` → `./infrastructure/external-dns` (wait: true)
- `cnpg.yaml` - Flux Kustomization `cnpg` → `./infrastructure/cnpg` (wait: true) — installs the CloudNativePG operator + CRDs consumed by jellystat's Postgres `Cluster`
- `crossplane.yaml` - Flux Kustomization `crossplane` → **argus** `./infrastructure/crossplane` (sourceRef GitRepository `flux-system`, i.e. the argus repo — the path does not exist in atlas)
- `crossplane-zitadel.yaml` - Flux Kustomization `crossplane-zitadel` → **argus** `./infrastructure/crossplane-zitadel` (dependsOn crossplane). Provider package only.
- `crossplane-resources.yaml` - Flux Kustomization `crossplane-resources` → `./clusters/production/crossplane` (dependsOn crossplane-zitadel, **prune: false**)

**crossplane/** - Zitadel ProviderConfig + OIDC apps (ns `zitadel`)

- `namespace.yaml` - Namespace `zitadel`
- `external-secret.yaml` - ESO `ExternalSecret` `crossplane-provider-zitadel` ← Vault `secrets-production/zitadel/crossplane` (property `credentials`, a Zitadel JWT-profile JSON, populated out of band) via the `vault-backend` ClusterSecretStore
- `providerConfig.yaml` - Zitadel `ProviderConfig` `default` (`zitadel.didactiklabs.io/v1beta1`) → that secret
- `oidc-jellyfin.yaml` - `Oidc` app for jellyfin's in-app SSO plugin (redirect URIs at `jellyfin.rpcu.io/sso/...` + TwoFactorAuth callback), project `370001231784969038` ("public"), connection secret `jellyfin-oidc` → ns media
- `oidc-radarr.yaml` / `oidc-prowlarr.yaml` / `oidc-qbittorrent.yaml` - `Oidc` apps for the oauth2-proxy fronting each app (redirect `https://<app>.production.rpcu.lan/oauth2/callback`), project `370001231734928333` ("administration"), connection secrets `<app>-oidc` → ns media
- `oidc-jellystat.yaml` - `Oidc` app for jellystat's oauth2-proxy (redirect `https://jellystat.production.rpcu.lan/oauth2/callback`), project `370001231734928333` ("administration"), connection secret `jellystat-oidc` → ns media
- `oidc-jellysweep.yaml` - `Oidc` app for jellysweep's **native** OIDC login (redirect `https://jellysweep.production.rpcu.lan/auth/oidc/callback`), project `370001231784969038` ("public"), **role assertion enabled** (id/access token + userinfo) so the argus `groupsClaim` action surfaces the `groups` claim jellysweep matches against `admin_group: public-admin`. Connection secret `jellysweep-oidc` → ns media

> **Shared Zitadel ownership.** The Zitadel org `rpcu` (`369994019545117645`)
> and its projects are OWNED by the argus openstack cluster overlay. Atlas
> only manages its own `Oidc` apps and references org/project by **literal
> external ID** (an `orgIdRef`/`projectIdRef` would never resolve here).
> `crossplane-resources` is `prune: false` so removing an Oidc from Git does
> not delete the live Zitadel app — clean up manually and beware two clusters
> fighting over the same external object.

**Apps** (all in namespace `media`; the namespace is declared in
`jellyfin/namespace.yaml` with `kustomize.toolkit.fluxcd.io/prune: disabled`):

- `jellyfin/` - Media server, image `jellyfin/jellyfin:10.11.11`
  - `deploy.yaml` - Deployment (1 replica, Recreate, fsGroup 1000, postStart sed hacks on the jellyfin-web bundle, GPU passthrough TODO/commented)
  - `service.yaml` - ClusterIP 8096, `appProtocol: kubernetes.io/wss` (WebSocket)
  - `httproute.yaml` - **Public**: `jellyfin.rpcu.io` on the `https-external` Gateway, 3600s timeouts. No oauth2-proxy — auth is the in-app Zitadel SSO plugin
  - `pvc.yaml` - `config` 10Gi RWO, `cache` 30Gi RWO, `transcodes` 100Gi RWO (default SC = Cinder). Media libraries served from the shared `media` PVC via subPath
  - `cm.yaml` + `custom-css-cm.yaml` - jellyfin-web `config.json` + custom CSS
  - `pushsecret-oidc.yaml` - ESO `PushSecret`: `jellyfin-oidc` → Vault `secrets-production/jellyfin/oidc`
- `radarr/` - Movie manager, image `ghcr.io/linuxserver/radarr:6.2.1-nightly`
  - `deploy.yaml` - AUTHENTICATION_METHOD=External, API key injected via postStart from ExternalSecret; mounts `radarr-config` + shared `media` PVC (subPath: `movies`, `downloads`)
  - `httproute.yaml` - **Internal**: `radarr.production.rpcu.lan` on the Sveltos-pushed `https` Gateway → backend `radarr-oauth2-proxy:80`
  - `secrets.yaml` - ExternalSecret `radarr-secrets` (API_KEY ← Vault `secrets-production/radarr/config`)
  - `pushsecret-oidc.yaml` - PushSecret `radarr-oidc` → Vault `secrets-production/radarr/oidc`
  - `oauth2-proxy/` - HelmRelease `radarr-oauth2-proxy` (chart oauth2-proxy v10.6.0), OIDC issuer `https://rpcu-gabeck.eu1.zitadel.cloud`, client id/secret straight from the Crossplane connection secret (`attribute.client_id`/`attribute.client_secret` keys), cookie secret ← Vault `secrets-production/oauth2-proxy/config`
- `prowlarr/` - Indexer manager, image `ghcr.io/linuxserver/prowlarr:2.4.0-nightly` + flaresolverr-compatible sidecar `ghcr.io/thephaseless/byparr:main` (digest-pinned, port 8191). Same pattern as radarr (`prowlarr.production.rpcu.lan`, oauth2-proxy, Vault `secrets-production/prowlarr/*`)
- `qbittorrent/` - Torrent client, image `binhex/arch-qbittorrentvpn:5.2.3-1-01`, **privileged** (wireguard VPN support; `VPN_ENABLED` currently "no"; wg0.conf ← Vault `secrets-production/qbittorrent/config`). Mounts `qbittorrent-config` (RWO) + shared `media` PVC (subPath: `downloads`, `movies`, `tvshows`). Internal HTTPRoute behind oauth2-proxy like the arrs
- `bazarr/` - Subtitle manager, image `ghcr.io/linuxserver/bazarr:1.5.7-development` (adapted from `../bealv`). No API key ExternalSecret (bazarr auth is set to External via oauth2-proxy; no `secrets.yaml`). Mounts `bazarr-config` (RWO) + shared `media` PVC (subPath: `movies`, `tvshows`, `animes`, `downloads`). Same pattern as the arrs (`bazarr.production.rpcu.lan`, oauth2-proxy → `bazarr.media:6767`, `pushsecret-oidc.yaml` → Vault `secrets-production/bazarr/oidc`)
- `jellystat/` - Jellyfin statistics app, image `cyfershepard/jellystat:1.1.11`. **Internal** behind oauth2-proxy at `jellystat.production.rpcu.lan` (oauth2-proxy → `jellystat.media:3000`, project `370001231734928333` "administration", `pushsecret-oidc.yaml` → Vault `secrets-production/jellystat/oidc`). Needs a **Postgres** DB provisioned via **CNPG**:
  - `cnpg.yaml` - CNPG `Cluster` `jellystat-postgres` (1 instance, 10Gi on default Cinder SC, bootstrap db `jfstat`/owner `jellystat`). CNPG exposes the RW service `jellystat-postgres-rw` which the app connects to via `POSTGRES_IP`.
  - `secrets.yaml` - ExternalSecret `jellystat-db` ← Vault `secrets-production/jellystat/config` (`username`/`password`/`jwtSecret`), templated as a `kubernetes.io/basic-auth` secret so CNPG can consume it as the bootstrap secret AND the app can read `POSTGRES_USER`/`POSTGRES_PASSWORD`/`JWT_SECRET`. **Populate this Vault path out of band before deploy.**
  - `deploy.yaml` - Deployment (1 replica, Recreate), backup PVC `jellystat-backup` (5Gi RWO) mounted at `/app/backend/backup-data`
- `jellysweep/` - Smart Jellyfin cleanup tool, image `ghcr.io/jon4hz/jellysweep:v0.15.0`. **Internal** at `jellysweep.production.rpcu.lan` but uses **native Zitadel OIDC** (NOT oauth2-proxy) — the HTTPRoute points straight at `jellysweep:3002`. `dry_run: false` (**live deletions**), cleanup_mode `all`. Plugged into the whole stack: connects to `jellyfin.media:8096`, `sonarr.media:8989`, `radarr.media:7878`, `seerr.media:5055` (jellyseerr) and `jellystat.media:3000` via API keys.
  - `cm.yaml` - ConfigMap `jellysweep-config` (`config.yml`: libraries `Movies`/`TV Shows` — names must match Jellyfin library names, service URLs, OIDC auth block with `admin_group: public-admin`, SQLite DB at `/app/data/jellysweep.db`). Secret values (API keys, session key, OIDC client id/secret) are injected via `JELLYSWEEP_*` env vars which override the file.
  - `secrets.yaml` - ExternalSecret `jellysweep-secrets`: `session-key`/`jellyfin-api-key`/`seerr-api-key`/`jellystat-api-key` ← Vault `secrets-production/jellysweep/config` (**populate out of band**); **reuses** existing `radarr-api-key` ← `secrets-production/radarr/config` and `sonarr-api-key` ← `secrets-production/sonarr/config`.
  - OIDC (`oidc-jellysweep.yaml`, project `370001231784969038` "public", redirect `.../auth/oidc/callback`, role assertion enabled so the argus `groupsClaim` action surfaces the `groups` claim). `admin_group` = `public-admin`. `pushsecret-oidc.yaml` → Vault `secrets-production/jellysweep/oidc`.
  - `pvc.yaml` - `jellysweep-data` 2Gi RWO for the SQLite DB

**Gaming Apps** (in namespace `gaming`; the namespace is declared in
`palworld/namespace.yaml` with `kustomize.toolkit.fluxcd.io/prune: disabled`):

- `palworld/` - Palworld dedicated game server, image `thijsvanloef/palworld-server-docker:latest`
  - `namespace.yaml` - Namespace `gaming` (prune disabled)
  - `deploy.yaml` - Deployment (1 replica, Recreate, fsGroup 1000, 4-8Gi RAM, 0.5-2 CPU). Env vars from ConfigMap (`palworld-config`) via `envFrom`, secrets (`ADMIN_PASSWORD`/`SERVER_PASSWORD`) from direct Secret `palworld-secrets`. Single volume mount `/palworld` from PVC `palworld-data`
  - `service.yaml` - NodePort service: ports 8211 UDP (game), 27015 UDP (query), 8212 TCP (REST API), 25575 TCP (RCON)
  - `httproute.yaml` - **Public**: `palworld.rpcu.io` on the `https-external` Gateway → backend `palworld:8212` (REST API only; game traffic is UDP via NodePort)
  - `pvc.yaml` - `palworld-data` 25Gi RWO (default Cinder SC) for server files, saves, and backups
  - `cm.yaml` - ConfigMap `palworld-config` (server settings: 16 players, multithreading enabled, daily backups, RCON enabled, game rate defaults)
  - `secret.yaml` - Direct Kubernetes Secret `palworld-secrets` (`ADMIN_PASSWORD`, `SERVER_PASSWORD`) — **NOT via Vault/ESO**, managed manually. **Change default values before pushing!**

### infrastructure/ - Production-Specific Glue

**cert-manager/** — NOT a cert-manager install (that comes from Sveltos).
Only the public ACME issuer:

- `clusterissuer.yaml` - `ClusterIssuer` `rpcuio` (Let's Encrypt production, DNS-01 via **Cloudflare**) + ExternalSecret `cert-manager-cloudflare-external` (api-key ← Vault `secrets-production/cloudflare/api`)

**external-dns/** — A SECOND ExternalDNS instance for the **public Cloudflare
zone** `rpcu.io` (distinct from the argus/Sveltos internal ExternalDNS that
targets Designate/`production.rpcu.lan`):

- `helmrelease.yaml` - HelmRelease `external-dns` (ns `external-dns`, chart version `1.21.1`; sourceRef reuses the argus-owned HelmRepository `external-dns` in ns `internal-dns` → `https://kubernetes-sigs.github.io/external-dns/`). `provider: cloudflare`, `txtOwnerId: production`, `domainFilters: [rpcu.io]`, `policy: sync`, sources ingress + gateway-httproute
- `secrets.yaml` - ExternalSecret `external-dns-cloudflare` (api-token ← Vault `secrets-production/cloudflare/api`)

**kgateway/** — NOT a kgateway install (controller comes from Sveltos).
Only the public Gateway:

- `gateway.yaml` - Gateway `https-external` (ns kgateway-system, gatewayClassName `kgateway`, **static address `172.16.255.10`**, GatewayParameters `gwp-static-ip`), listeners HTTP/HTTPS for `*.rpcu.io`, TLS Terminate with `rpcu-io-wildcard-tls` (annotation `cert-manager.io/cluster-issuer: rpcuio`), 128Mi per-connection buffer; + HTTPRoute `https-redirect-external` (301 → https)

**cnpg/** — The **CloudNativePG** Postgres operator (NOT argus/Sveltos-provided; installed HERE because no repo previously needed Postgres). Consumed by jellystat's `Cluster` CR:

- `namespace.yaml` - Namespace `cnpg-system`
- `helmrepo.yaml` - HelmRepository `cloudnative-pg` → `https://cloudnative-pg.github.io/charts`
- `helmrelease.yaml` - HelmRelease `cloudnative-pg` (chart `cloudnative-pg` **0.29.0**, appVersion 1.30.0), installs the `postgresql.cnpg.io` CRDs (`crds.create: true`, install `Create` / upgrade `CreateReplace`)

---

## 2. Key Configuration Details

### Two Gateways, two DNS zones, two cert chains

| —            | Public                                                       | Internal                                            |
| ------------ | ------------------------------------------------------------ | --------------------------------------------------- |
| Gateway      | `https-external` (defined HERE)                              | `https` (Sveltos-pushed from argus)                 |
| Hostname     | `*.rpcu.io`                                                  | `*.production.rpcu.lan`                             |
| Address      | static `172.16.255.10`                                       | Octavia-assigned floating IP                        |
| Certificates | Let's Encrypt via `rpcuio` ClusterIssuer (Cloudflare DNS-01) | Vault PKI via `vault-issuer` (argus)                |
| DNS sync     | ExternalDNS → Cloudflare (defined HERE)                      | ExternalDNS → Designate (Sveltos add-on)            |
| Users        | jellyfin                                                     | radarr, prowlarr, qbittorrent (behind oauth2-proxy) |

### Storage

**No StorageClass/CSI manifests live in this repo.** Storage drivers are
argus/Sveltos-delivered:

- **RWO (default)**: `csi-cinder-sc-delete` — OpenStack Cinder CSI. PVCs that
  omit `storageClassName` land here (all the `*-config`, `cache`, `transcodes`).
- **RWX**: `ceph-cephfs` — despite the name, this is the **csi-driver-nfs**
  StorageClass (`provisioner: nfs.csi.k8s.io`, server `10.0.0.245`, share
  `/rpcu-fs`): CephFS storage from the argus openstack Rook cluster, consumed
  over NFS via the Rook `CephNFS` gateway. The `ceph-cephfs` name was
  deliberately kept when argus replaced the direct ceph-csi-cephfs driver
  (which could never provision from VMs — the Rook cluster is pod-networked),
  so atlas PVC manifests did not need to change. Defined in argus at
  `infrastructure/csi-driver-nfs/storageclass.yaml`.
- The `media` PVC (900Gi RWX on `ceph-cephfs`) is a **single consolidated
  volume** shared across all media apps via `subPath` mounts. It contains
  `movies/`, `tvshows/`, `animes/`, and `downloads/` subdirectories, enabling
  hardlinks between downloads and library folders (required for the *arr stack).
  This replaced the former 4 separate PVCs (`movies`, `tvshows`, `animes`,
  `qbittorrent-downloads`) which could not support cross-PVC hardlinks.
- PVC `spec` is immutable once created (except size increase). Changing a
  PVC's `storageClassName` in Git requires deleting/recreating the live PVC
  (data migration!) — never do this casually on the media libraries.

### Secrets (Vault via ESO)

All secrets flow through the `vault-backend` ClusterSecretStore (provisioned by
the argus Sveltos `vault-auth` add-on; Vault = `https://vault.mgmt.rpcu.lan`,
KV-v2 mount `secrets-production`). Paths in use:

- `secrets-production/cloudflare/api` — Cloudflare token (cert-manager DNS-01 + public ExternalDNS)
- `secrets-production/zitadel/crossplane` — Zitadel JWT-profile credentials for provider-zitadel (populated out of band)
- `secrets-production/{radarr,prowlarr,sonarr}/config` — app API keys (`API_KEY`; sonarr/radarr keys are also reused by jellysweep)
- `secrets-production/qbittorrent/config` — wireguard `wg0.conf`
- `secrets-production/oauth2-proxy/config` — shared oauth2-proxy cookie secret
- `secrets-production/jellystat/config` — jellystat Postgres `username`/`password` + `jwtSecret` (bootstrap secret for the CNPG cluster AND app creds; **populate out of band**)
- `secrets-production/jellysweep/config` — jellysweep `sessionKey` + `jellyfinApiKey`/`seerrApiKey`/`jellystatApiKey` (**populate out of band**)
- `secrets-production/{jellyfin,radarr,prowlarr,qbittorrent,jellystat,jellysweep,...}/oidc` — **PushSecrets** (written BY the cluster): the Crossplane Oidc connection secrets are pushed UP to Vault for backup/reuse. Note PushSecret requires the per-cluster Vault policy to allow create/update, not just read.

### Version Pins

| Component      | Version                   | Where                                                                             |
| -------------- | ------------------------- | --------------------------------------------------------------------------------- |
| oauth2-proxy   | 10.6.0 (chart)            | `clusters/production/{radarr,prowlarr,qbittorrent}/oauth2-proxy/helmrelease.yaml` |
| jellyfin       | 10.11.11                  | `clusters/production/jellyfin/deploy.yaml`                                        |
| radarr         | 6.2.1-nightly             | `clusters/production/radarr/deploy.yaml`                                          |
| prowlarr       | 2.4.0-nightly             | `clusters/production/prowlarr/deploy.yaml`                                        |
| byparr         | main (digest-pinned)      | `clusters/production/prowlarr/deploy.yaml`                                        |
| qbittorrentvpn | 5.2.3-1-01                | `clusters/production/qbittorrent/deploy.yaml`                                     |
| external-dns   | 1.21.1 (chart)            | `infrastructure/external-dns/helmrelease.yaml`                                    |
| jellystat      | 1.1.11                    | `clusters/production/jellystat/deploy.yaml`                                       |
| jellysweep     | v0.15.0                   | `clusters/production/jellysweep/deploy.yaml`                                      |
| cloudnative-pg | 0.29.0 (chart)            | `infrastructure/cnpg/helmrelease.yaml`                                            |
| palworld       | latest                    | `clusters/production/palworld/deploy.yaml`                                        |

Crossplane / provider-zitadel / kgateway / cert-manager versions are pinned in
**argus**, not here.

### Dependency Updates (Renovate)

`renovate.json5` drives dependency-update PRs. Renovate runs **self-hosted in
GitHub Actions** (`.github/workflows/renovate.yaml`, the
`renovatebot/github-action`) — NOT via the Mend-hosted App — mirroring the argus
setup. **No auto-merge**, PRs batched Monday early morning (`Europe/Paris`),
Dependency Dashboard issue.

**Runner + auth (self-hosted).** The workflow runs hourly (`cron: 0 * * * *`)
plus `workflow_dispatch` (`dryRun`/`logLevel` inputs); Renovate's own `schedule`
gates when branches/PRs are created, so hourly runs are cheap no-ops outside the
window (a manual dispatch bypasses the window via `RENOVATE_FORCE`). It mints a
short-lived token from the org **`rpcu-bot` GitHub App** (app_id `3164565`) via
`actions/create-github-app-token@v1`, reusing the org-level `APP_ID` /
`PRIVATE_KEY` secrets already granted to atlas (no repo-level secrets). The Mend
`renovate` App (app_id `2740`) is installed org-wide; exclude atlas from it (or
uninstall) so it does not double-run against this repo.

**Managers.** Built-in: `flux` (HelmReleases in `clusters/**` +
`infrastructure/**`), `helm-values`, `kustomize`, `github-actions`. Custom regex
managers mirror the argus ones: GitHub release-download /
`raw.githubusercontent.com` URLs, `?ref=vX` kustomize bases, annotated bare
`tag:` pins, and plain `image: repo:tag` in raw manifests (this is what tracks
the app images).

**Grouping (packageRules):** the six per-app `oauth2-proxy` HelmReleases are
grouped into one PR; the LinuxServer `*arr` images
(`ghcr.io/linuxserver/*`) are grouped and `pinDigests: true` (their moving
`-nightly`/`-develop`/`-development` tags are only trackable by digest). `major`
updates get `major-update`/`needs-careful-review` labels.

**Manifest-side pinning (all images now under Renovate).** Previously-invisible
deps were pinned so Renovate can raise PRs:
`clusters/production/qbittorrent/deploy.yaml` `binhex/arch-qbittorrentvpn` is now
tagged `5.2.3-1-01` (tracked via docker datasource);
`infrastructure/external-dns/helmrelease.yaml` pins chart `version: "1.21.1"`
(HelmRepository → `https://kubernetes-sigs.github.io/external-dns/`, argus-owned
in ns `internal-dns`). Two images ship no semver tags — `byparr:main`
(`clusters/production/prowlarr/deploy.yaml`, only `latest`/`main`/`nightly`
exist) and the seerr fork build `zadki3l/seerr:michaelhthomas-oidc-<sha>`
(`clusters/production/seerr/deploy.yaml`) — so a `packageRules` entry in
`renovate.json5` sets `pinDigests: true` for both, making Renovate pin and track
their digests (the only reproducible update path for a moving/branch tag).

---

## 3. Deployment & Sync Process

Reconciliation order (from `clusters/production/`):

1. **Sveltos prerequisites** (argus-side, not in this repo): Cilium → Flux →
   ESO/vault-auth → cert-manager → gateway-api/kgateway → cinder-csi →
   csi-driver-nfs → internal external-dns
2. **atlas** GitRepository + Kustomization (self-reconciling root, applies everything below)
3. **cert-manager-issuer** → ACME `rpcuio` ClusterIssuer (needs cert-manager + vault-backend)
4. **kgateway-external** → public `https-external` Gateway (needs kgateway controller + `gwp-static-ip`)
5. **external-dns** → Cloudflare ExternalDNS (needs the argus HelmRepository in ns internal-dns + vault-backend)
6. **cnpg** → CloudNativePG operator Helm install (provides `postgresql.cnpg.io` CRDs before jellystat's `Cluster` is applied)
7. **crossplane** → Crossplane Helm install from the ARGUS repo
8. **crossplane-zitadel** (dependsOn crossplane) → provider-zitadel package from the ARGUS repo
9. **crossplane-resources** (dependsOn crossplane-zitadel, prune: false) → ProviderConfig + the Oidc apps
10. **Apps** (applied directly by the `atlas` Kustomization, no per-app Flux Kustomizations): jellyfin, radarr, prowlarr, qbittorrent, sonarr, seerr, bazarr, jellystat, jellysweep — each oauth2-proxy'd app's HelmRelease waits on its `<app>-oidc` connection secret (written by Crossplane) and the cookie-secret ExternalSecret; jellystat additionally waits on the CNPG `jellystat-postgres` cluster; jellysweep uses native OIDC (no oauth2-proxy)

---

## 4. Making Changes

### Common Tasks

**Add a new app behind the internal Gateway + oauth2-proxy** (copy the radarr pattern):

1. Create `clusters/production/<app>/` (deploy, service, pvc, httproute → `<app>.production.rpcu.lan` with backend `<app>-oauth2-proxy:80`, oauth2-proxy/ dir)
2. Add an `Oidc` CR in `clusters/production/crossplane/oidc-<app>.yaml` (project `370001231734928333`, redirect `https://<app>.production.rpcu.lan/oauth2/callback`, connection secret `<app>-oidc` → media) and list it in `crossplane/kustomization.yaml`
3. Add the app dir to `clusters/production/kustomization.yaml`
4. Optionally a `pushsecret-oidc.yaml` to back up the client credentials to Vault

**Expose an app publicly**: HTTPRoute on `https-external` with hostname
`<app>.rpcu.io` — the Cloudflare ExternalDNS + Let's Encrypt wildcard handle
DNS/TLS automatically.

**Add an RWX volume**: set `storageClassName: ceph-cephfs` + `ReadWriteMany`.
RWO volumes should omit `storageClassName` (cluster default = Cinder).

### Development Workflow

1. Create feature branch, make YAML changes
2. `devenv shell` → pre-commit hooks (shellcheck, treefmt/prettier/nixfmt)
3. Validate: `kustomize build clusters/production/`
4. Push, PR to main; Flux picks up main within ~1m of merge
5. Force a sync: `flux reconcile source git atlas -n flux-system && flux reconcile kustomization atlas -n flux-system`

---

## 5. Important Notes for AI Agents

### Commit Policy

**⚠️ DO NOT COMMIT CHANGES UNLESS EXPLICITLY ASKED** (preview diff, list files, draft message, wait for approval).

### File Safety

- Do NOT commit secrets — everything sensitive flows through Vault/ESO
- Do NOT delete `crossplane-resources` objects casually: `prune: false` means
  Git deletion does NOT clean up the live Zitadel apps; and the shared org/
  projects belong to argus
- Do NOT change PVC `storageClassName`/`accessModes` on live volumes — PVC
  spec is immutable; media-library PVCs hold real data
- The `media` namespace has `prune: disabled` — deleting an app dir does not
  delete the namespace or surviving PVCs (intentional)

### Cluster Safety

- Kubeconfig: `~/.kube/configs/rpcu/kubernetes-admin@production.kubeconfig`
- Remember the split-brain with argus: platform failures (Gateway missing,
  vault-backend not Ready, StorageClass absent) are fixed in **argus**, app
  failures here
- `kustomize build clusters/production/` must succeed before pushing
- Verify reconciliation: `flux get kustomizations -A` on the production cluster

### Helpful Commands

```bash
# Flux status (production cluster)
flux get kustomizations -A
flux get helmreleases -A
flux reconcile kustomization atlas -n flux-system --with-source

# App health
kubectl -n media get pods,pvc
kubectl get gateway,httproute -A

# Crossplane OIDC apps
kubectl get oidc -A
kubectl -n media get secret jellyfin-oidc radarr-oidc prowlarr-oidc qbittorrent-oidc

# Storage
kubectl get storageclass
```

---

## 6. Summary

Atlas is the **application layer** for RPCU's production cluster:

✅ Media stack (jellyfin, radarr, prowlarr, qbittorrent) declared as plain manifests
✅ OIDC SSO for every app via Crossplane-managed Zitadel clients (+ oauth2-proxy for the arrs)
✅ Public (`*.rpcu.io`, Cloudflare/Let's Encrypt) and internal (`*.production.rpcu.lan`, Vault PKI/Designate) ingress split across two Gateways
✅ All secrets via Vault + External Secrets Operator (read AND push-back)
✅ RWO storage from Cinder, single RWX `media` PVC on CephFS-over-NFS (`ceph-cephfs`) — drivers delivered by argus/Sveltos
✅ Platform substrate (cluster, CNI, Flux, kgateway, cert-manager, CSI) owned by the argus repo

---

**Last Updated**: July 2026 (Added Palworld dedicated game server in new `gaming` namespace — NodePort for UDP game/query ports, HTTPRoute for REST API on `palworld.rpcu.io`, direct K8s Secret for passwords, 25Gi Cinder PVC. — Prior: Pinned byparr to `main` with digest on GHCR (was `latest`-only, Renovate tracks `main` tag via `pinDigests: true`). — Prior: Closed Renovate coverage gaps: pinned `binhex/arch-qbittorrentvpn:5.2.3-1-01` and external-dns chart `1.21.1`, added a `renovate.json5` `packageRules` entry setting `pinDigests: true` for the two no-semver images — all container images + charts are now trackable. — Prior: Consolidated media storage: merged 4 separate RWX PVCs into a single `media` PVC (900Gi) to enable hardlinks, updated all 5 app deployments to `subPath` mounts.)
**Repository**: <https://github.com/RPCU/atlas.git>
**Main Branch**: main
**Cluster**: production (CAPI workload cluster, managed from argus mgmt)
