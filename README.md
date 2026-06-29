# Atlas

Single-cluster GitOps repository for the **production** cluster. Flux is deployed
via Sveltos from the management cluster and reconciles this repo using the
`GitRepository` + `Kustomization` CRs defined here.

## Structure

```
clusters/production/
├── kustomization.yaml          # kustomize build config
├── gitrepository.yaml          # Flux GitRepository → atlas.git
└── flux-kustomization.yaml     # Flux Kustomization → reconciles this directory
```

## How it works

1. The management cluster's Sveltos deploys Flux (Operator + Instance) to the
   production cluster.
2. The `GitRepository` CR tells Flux to pull from `https://github.com/RPCU/atlas.git`.
3. The `Kustomization` CR tells Flux to reconcile `./clusters/production`, which
   applies the kustomize build config and all resources listed there.

## Dev environment

Requires [devenv](https://devenv.sh). Run `devenv shell` to get:

- `fluxcd`, `kustomize`, `kubernetes-helm`
- `jq`, `yq`
- Git hooks (shellcheck, treefmt)
