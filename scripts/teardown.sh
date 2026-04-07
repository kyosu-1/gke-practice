#!/bin/bash
set -euo pipefail

PROJECT_ID="gke-practice-kyosu"
ZONE="asia-northeast1-a"
CLUSTER_NAME="gke-practice"
TFSTATE_BUCKET="${PROJECT_ID}-tfstate"

echo "=== GKE Practice Teardown ==="
echo "Project: ${PROJECT_ID}"
echo ""
read -p "全リソースを削除します。続行しますか？ (y/N): " confirm
[[ "$confirm" =~ ^[yY]$ ]] || { echo "中止しました"; exit 0; }

# 1. ArgoCD & bootstrap Applications 削除
echo ""
echo "--- ArgoCD Applications 削除 ---"
kubectl delete -f argocd/applications/root.yaml --ignore-not-found
kubectl delete -f argocd/bootstrap/image-updater.yaml --ignore-not-found
kubectl delete -f argocd/bootstrap/external-secrets.yaml --ignore-not-found
kubectl delete -n argocd -f "https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.6/manifests/install.yaml" --ignore-not-found
for ns in argocd external-secrets dev prod; do
  kubectl delete namespace "$ns" --ignore-not-found
done

# 2. GCP Secret Manager のシークレット削除
echo ""
echo "--- Secret Manager 削除 ---"
for secret in argocd-github-client-id argocd-github-client-secret \
              argocd-image-updater-github-app-id \
              argocd-image-updater-github-app-installation-id \
              argocd-image-updater-github-app-key; do
  gcloud secrets delete "$secret" --quiet 2>/dev/null || true
done

# 3. Terraform destroy
echo ""
echo "--- Terraform destroy ---"
cd terraform
terraform destroy -auto-approve
cd ..

# 4. Terraform state バケット削除
echo ""
echo "--- tfstate バケット削除 ---"
gcloud storage rm -r "gs://${TFSTATE_BUCKET}" 2>/dev/null || true

echo ""
echo "=== Teardown 完了 ==="
echo "プロジェクト自体を削除する場合: gcloud projects delete ${PROJECT_ID}"
