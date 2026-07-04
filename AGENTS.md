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
- `crossplane.yaml` - Flux Kustomization `crossplane` → **argus** `./infrastructure/crossplane` (sourceRef GitRepository `flux-system`, i.e. the argus repo — the path does not exist in atlas)
- `crossplane-zitadel.yaml` - Flux Kustomization `crossplane-zitadel` → **argus** `./infrastructure/crossplane-zitadel` (dependsOn crossplane). Provider package only.
- `crossplane-resources.yaml` - Flux Kustomization `crossplane-resources` → `./clusters/production/crossplane` (dependsOn crossplane-zitadel, **prune: false**)

**crossplane/** - Zitadel ProviderConfig + OIDC apps (ns `zitadel`)

- `namespace.yaml` - Namespace `zitadel`
- `external-secret.yaml` - ESO `ExternalSecret` `crossplane-provider-zitadel` ← Vault `secrets-production/zitadel/crossplane` (property `credentials`, a Zitadel JWT-profile JSON, populated out of band) via the `vault-backend` ClusterSecretStore
- `providerConfig.yaml` - Zitadel `ProviderConfig` `default` (`zitadel.didactiklabs.io/v1beta1`) → that secret
- `oidc-jellyfin.yaml` - `Oidc` app for jellyfin's in-app SSO plugin (redirect URIs at `jellyfin.rpcu.io/sso/...` + TwoFactorAuth callback), project `370001231784969038` ("public"), connection secret `jellyfin-oidc` → ns media
- `oidc-radarr.yaml` / `oidc-prowlarr.yaml` / `oidc-qbittorrent.yaml` - `Oidc` apps for the oauth2-proxy fronting each app (redirect `https://<app>.production.rpcu.lan/oauth2/callback`), project `370001231734928333` ("administration"), connection secrets `<app>-oidc` → ns media

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
  - `pvc.yaml` - `config` 10Gi RWO, `cache` 30Gi RWO, `transcodes` 100Gi RWO (default SC = Cinder); `tvshows` 200Gi / `animes` 200Gi / `movies` 300Gi — **RWX on `ceph-cephfs`**
  - `cm.yaml` + `custom-css-cm.yaml` - jellyfin-web `config.json` + custom CSS
  - `pushsecret-oidc.yaml` - ESO `PushSecret`: `jellyfin-oidc` → Vault `secrets-production/jellyfin/oidc`
- `radarr/` - Movie manager, image `ghcr.io/linuxserver/radarr:6.2.1-nightly`
  - `deploy.yaml` - AUTHENTICATION_METHOD=External, API key injected via postStart from ExternalSecret; mounts `radarr-config` + the shared RWX PVCs `movies` and `qbittorrent-downloads`
  - `httproute.yaml` - **Internal**: `radarr.production.rpcu.lan` on the Sveltos-pushed `https` Gateway → backend `radarr-oauth2-proxy:80`
  - `secrets.yaml` - ExternalSecret `radarr-secrets` (API_KEY ← Vault `secrets-production/radarr/config`)
  - `pushsecret-oidc.yaml` - PushSecret `radarr-oidc` → Vault `secrets-production/radarr/oidc`
  - `oauth2-proxy/` - HelmRelease `radarr-oauth2-proxy` (chart oauth2-proxy v10.6.0), OIDC issuer `https://rpcu-gabeck.eu1.zitadel.cloud`, client id/secret straight from the Crossplane connection secret (`attribute.client_id`/`attribute.client_secret` keys), cookie secret ← Vault `secrets-production/oauth2-proxy/config`
- `prowlarr/` - Indexer manager, image `ghcr.io/linuxserver/prowlarr:2.4.0-nightly` + flaresolverr-compatible sidecar `ghcr.io/thephaseless/byparr:latest` (port 8191). Same pattern as radarr (`prowlarr.production.rpcu.lan`, oauth2-proxy, Vault `secrets-production/prowlarr/*`)
- `qbittorrent/` - Torrent client, image `binhex/arch-qbittorrentvpn` (untagged), **privileged** (wireguard VPN support; `VPN_ENABLED` currently "no"; wg0.conf ← Vault `secrets-production/qbittorrent/config`). Mounts `qbittorrent-config` (RWO) + RWX PVCs `qbittorrent-downloads`, `movies`, `tvshows`. Internal HTTPRoute behind oauth2-proxy like the arrs

### infrastructure/ - Production-Specific Glue

**cert-manager/** — NOT a cert-manager install (that comes from Sveltos).
Only the public ACME issuer:

- `clusterissuer.yaml` - `ClusterIssuer` `rpcuio` (Let's Encrypt production, DNS-01 via **Cloudflare**) + ExternalSecret `cert-manager-cloudflare-external` (api-key ← Vault `secrets-production/cloudflare/api`)

**external-dns/** — A SECOND ExternalDNS instance for the **public Cloudflare
zone** `rpcu.io` (distinct from the argus/Sveltos internal ExternalDNS that
targets Designate/`production.rpcu.lan`):

- `helmrelease.yaml` - HelmRelease `external-dns` (ns `external-dns`, chart version `"*"` — unpinned; sourceRef reuses the argus-owned HelmRepository `external-dns` in ns `internal-dns`). `provider: cloudflare`, `txtOwnerId: production`, `domainFilters: [rpcu.io]`, `policy: sync`, sources ingress + gateway-httproute
- `secrets.yaml` - ExternalSecret `external-dns-cloudflare` (api-token ← Vault `secrets-production/cloudflare/api`)

**kgateway/** — NOT a kgateway install (controller comes from Sveltos).
Only the public Gateway:

- `gateway.yaml` - Gateway `https-external` (ns kgateway-system, gatewayClassName `kgateway`, **static address `172.16.255.10`**, GatewayParameters `gwp-static-ip`), listeners HTTP/HTTPS for `*.rpcu.io`, TLS Terminate with `rpcu-io-wildcard-tls` (annotation `cert-manager.io/cluster-issuer: rpcuio`), 128Mi per-connection buffer; + HTTPRoute `https-redirect-external` (301 → https)

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
- The RWX PVCs (`movies`, `tvshows`, `animes`, `qbittorrent-downloads`) are
  **shared across app deployments** within ns `media` (radarr and qbittorrent
  mount jellyfin's library PVCs) — this is why RWX is required.
- PVC `spec` is immutable once created (except size increase). Changing a
  PVC's `storageClassName` in Git requires deleting/recreating the live PVC
  (data migration!) — never do this casually on the media libraries.

### Secrets (Vault via ESO)

All secrets flow through the `vault-backend` ClusterSecretStore (provisioned by
the argus Sveltos `vault-auth` add-on; Vault = `https://vault.mgmt.rpcu.lan`,
KV-v2 mount `secrets-production`). Paths in use:

- `secrets-production/cloudflare/api` — Cloudflare token (cert-manager DNS-01 + public ExternalDNS)
- `secrets-production/zitadel/crossplane` — Zitadel JWT-profile credentials for provider-zitadel (populated out of band)
- `secrets-production/{radarr,prowlarr}/config` — app API keys
- `secrets-production/qbittorrent/config` — wireguard `wg0.conf`
- `secrets-production/oauth2-proxy/config` — shared oauth2-proxy cookie secret
- `secrets-production/{jellyfin,radarr,prowlarr,qbittorrent}/oidc` — **PushSecrets** (written BY the cluster): the Crossplane Oidc connection secrets are pushed UP to Vault for backup/reuse. Note PushSecret requires the per-cluster Vault policy to allow create/update, not just read.

### Version Pins

| Component      | Version                   | Where                                                                             |
| -------------- | ------------------------- | --------------------------------------------------------------------------------- |
| oauth2-proxy   | 10.6.0 (chart)            | `clusters/production/{radarr,prowlarr,qbittorrent}/oauth2-proxy/helmrelease.yaml` |
| jellyfin       | 10.11.11                  | `clusters/production/jellyfin/deploy.yaml`                                        |
| radarr         | 6.2.1-nightly             | `clusters/production/radarr/deploy.yaml`                                          |
| prowlarr       | 2.4.0-nightly             | `clusters/production/prowlarr/deploy.yaml`                                        |
| byparr         | latest (⚠ unpinned)      | `clusters/production/prowlarr/deploy.yaml`                                        |
| qbittorrentvpn | untagged (⚠ unpinned)    | `clusters/production/qbittorrent/deploy.yaml`                                     |
| external-dns   | `"*"` (⚠ unpinned chart) | `infrastructure/external-dns/helmrelease.yaml`                                    |

Crossplane / provider-zitadel / kgateway / cert-manager versions are pinned in
**argus**, not here.

### Dependency Updates (Renovate)

`renovate.json5` configures the Mend Renovate GitHub App: **no auto-merge**,
PRs batched Monday early morning (`Europe/Paris`), Dependency Dashboard issue.
Built-in managers: `flux` (HelmReleases in `clusters/**` + `infrastructure/**`),
`helm-values`, `kustomize`. Custom regex managers mirror the argus ones:
GitHub release-download / `raw.githubusercontent.com` URLs, `?ref=vX` kustomize
bases, annotated bare `tag:` pins, and plain `image: repo:tag` in raw manifests
(this is what tracks the app images). `major` updates get
`major-update`/`needs-careful-review` labels. The unpinned images/charts above
are invisible to Renovate until pinned.

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
6. **crossplane** → Crossplane Helm install from the ARGUS repo
7. **crossplane-zitadel** (dependsOn crossplane) → provider-zitadel package from the ARGUS repo
8. **crossplane-resources** (dependsOn crossplane-zitadel, prune: false) → ProviderConfig + the 4 Oidc apps
9. **Apps** (applied directly by the `atlas` Kustomization, no per-app Flux Kustomizations): jellyfin, radarr, prowlarr, qbittorrent — each app's oauth2-proxy HelmRelease waits on its `<app>-oidc` connection secret (written by Crossplane) and the cookie-secret ExternalSecret

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
✅ RWO storage from Cinder, RWX from CephFS-over-NFS (`ceph-cephfs`) — drivers delivered by argus/Sveltos
✅ Platform substrate (cluster, CNI, Flux, kgateway, cert-manager, CSI) owned by the argus repo

---

**Last Updated**: July 04, 2026 (Updated seerr OIDC postStart script; verified RWO/RWX storage configuration.)
**Repository**: <https://github.com/RPCU/atlas.git>
**Main Branch**: main
**Cluster**: production (CAPI workload cluster, managed from argus mgmt)
