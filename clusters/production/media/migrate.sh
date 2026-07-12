#!/usr/bin/env bash
# media-migrate.sh — Consolidate 4 RWX PVCs into a single `media` PVC
# Creates the PVC, migrates data, and cleans up old PVCs.
#
# Usage:
#   KUBECONFIG=~/.kube/configs/rpcu/kubernetes-admin@production.kubeconfig \
#   bash clusters/production/media/migrate.sh
set -euo pipefail

NS="media"
NEW_PVC="media"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KUBECTL="rtk kubectl -n $NS"

echo "==> Creating PVC '$NEW_PVC'..."
$KUBECTL apply -f "$SCRIPT_DIR/pvc.yaml"

echo "==> Waiting for PVC '$NEW_PVC' to be Bound..."
$KUBECTL wait --for=jsonpath='{.status.phase}'=Bound pvc/$NEW_PVC --timeout=300s

echo "==> Creating migration-helper pod..."
cat <<'POD' | $KUBECTL apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: migration-helper
spec:
  containers:
    - name: helper
      image: alpine:3.20
      command: ["sh", "-c", "apk add --no-cache rsync && sleep 86400"]
      volumeMounts:
        - name: media
          mountPath: /media
        - name: movies
          mountPath: /movies
        - name: tvshows
          mountPath: /tvshows
        - name: animes
          mountPath: /animes
        - name: downloads
          mountPath: /downloads
  volumes:
    - name: media
      persistentVolumeClaim:
        claimName: media
    - name: movies
      persistentVolumeClaim:
        claimName: movies
    - name: tvshows
      persistentVolumeClaim:
        claimName: tvshows
    - name: animes
      persistentVolumeClaim:
        claimName: animes
    - name: downloads
      persistentVolumeClaim:
        claimName: qbittorrent-downloads
  restartPolicy: Always
POD
echo "==> Waiting for migration-helper to be Ready..."
$KUBECTL wait --for=condition=Ready pod/migration-helper --timeout=120s

# Source PVC → target subPath on the new PVC, ordered smallest-first
ORDER=(movies tvshows qbittorrent-downloads animes)

for src in "${ORDER[@]}"; do
  echo ""
  echo "==> [$src] → [$src]"

  # Skip if migration already completed (marker file)
  marker=$($KUBECTL exec -i migration-helper -- sh -c "test -f /media/.migrated-$src && echo done" 2>/dev/null || true)
  if [ "$marker" = "done" ]; then
    echo "    Already migrated (marker found), skipping."
    continue
  fi

  echo "    Starting rsync..."
  $KUBECTL exec -i migration-helper -- rsync -avhP --hard-links "/$src/" "/media/$src/"

  # Write marker so re-runs skip completed PVCs
  $KUBECTL exec -i migration-helper -- sh -c "touch /media/.migrated-$src"

  echo "    Rsync complete. Verifying..."
  src_size=$($KUBECTL exec -i migration-helper -- du -sh "/$src" 2>/dev/null | awk '{print $1}')
  dst_size=$($KUBECTL exec -i migration-helper -- du -sh "/media/$src" 2>/dev/null | awk '{print $1}')
  echo "    Source: $src_size  |  Target: $dst_size"

  echo "    Deleting old PVC '$src'..."
  $KUBECTL delete pvc "$src" --wait=true
  echo "    Old PVC '$src' deleted."

  # Recreate the helper pod with updated volumes (old PVC removed)
  echo "    Recreating migration-helper pod..."
  $KUBECTL delete pod migration-helper --force --grace-period=0 2>/dev/null || true
  sleep 2
  cat <<'POD' | $KUBECTL apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: migration-helper
spec:
  containers:
    - name: helper
      image: alpine:3.20
      command: ["sh", "-c", "apk add --no-cache rsync && sleep 86400"]
      volumeMounts:
        - name: media
          mountPath: /media
  volumes:
    - name: media
      persistentVolumeClaim:
        claimName: media
  restartPolicy: Always
POD
  echo "    Waiting for migration-helper to be Ready..."
  $KUBECTL wait --for=condition=Ready pod/migration-helper --timeout=120s
done

echo ""
echo "==> Migration complete! All data is now on PVC '$NEW_PVC'."
echo "    Directory structure:"
$KUBECTL exec migration-helper -- ls -la /media/
echo ""
echo "==> Clean up the helper pod:"
echo "    kubectl -n $NS delete pod migration-helper"
echo ""
echo "==> Push the Git changes and Flux will roll out the updated deployments."
