# GKE Practice

Kubernetes, GKE, Terraform のベストプラクティスを実践的に学ぶためのプロジェクト。

## Architecture

```
go/services/echo/     Go HTTP API (echo service)
k8s/services/echo/    Kustomize manifests (base + overlays)
k8s/infra/            ClusterSecretStore, ExternalSecret
terraform/            GCP infrastructure (VPC, GKE, AR, IAM, WIF)
argocd/               ArgoCD Application manifests + config
.github/workflows/    CI (dynamic matrix) + Terraform CI
```

## Prerequisites

- [gcloud CLI](https://cloud.google.com/sdk/docs/install)
- [Terraform](https://developer.hashicorp.com/terraform/install) >= 1.14
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Docker](https://docs.docker.com/get-docker/)
- GCP アカウント + 課金有効

## Bootstrap (0 から構築)

### 1. GCP プロジェクト作成

```bash
gcloud projects create gke-practice-kyosu --name="GKE Practice"
gcloud billing projects link gke-practice-kyosu --billing-account=<BILLING_ACCOUNT_ID>
gcloud config set project gke-practice-kyosu

gcloud services enable \
  container.googleapis.com \
  artifactregistry.googleapis.com \
  iam.googleapis.com \
  compute.googleapis.com \
  cloudresourcemanager.googleapis.com \
  iamcredentials.googleapis.com \
  sts.googleapis.com
```

### 2. Terraform remote state 用バケット作成

```bash
gcloud storage buckets create gs://gke-practice-kyosu-tfstate \
  --location=asia-northeast1 \
  --uniform-bucket-level-access
```

### 3. Terraform apply

```bash
gcloud auth application-default login --project=gke-practice-kyosu

cd terraform
terraform init
terraform plan
terraform apply
```

作成されるリソース: VPC, GKE クラスタ, ノードプール, Artifact Registry, Workload Identity Federation, ESO 用 SA, Secret Manager API

### 4. kubectl 接続

```bash
gcloud components install gke-gcloud-auth-plugin
gcloud container clusters get-credentials gke-practice --zone asia-northeast1-a
kubectl get nodes  # Ready を確認
```

### 5. GitHub OAuth App 作成 & シークレット保存

1. [GitHub Settings > Developer settings > OAuth Apps](https://github.com/settings/developers) で OAuth App を作成
   - Homepage URL: `https://localhost:8443`
   - Authorization callback URL: `https://localhost:8443/api/dex/callback`

2. シークレットを GCP Secret Manager に保存:

```bash
echo -n "<CLIENT_ID>" | gcloud secrets create argocd-github-client-id --data-file=-
echo -n "<CLIENT_SECRET>" | gcloud secrets create argocd-github-client-secret --data-file=-
```

### 6. ArgoCD インストール & 設定

```bash
kubectl create namespace argocd
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.6/manifests/install.yaml
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s

# GitHub OAuth + RBAC 設定
kubectl apply -f argocd/config/argocd-cm-patch.yaml
kubectl apply -f argocd/config/argocd-rbac-cm-patch.yaml
```

### 7. External Secrets Operator (ESO) デプロイ

```bash
kubectl apply -f argocd/bootstrap/external-secrets.yaml

# ESO が Ready になるまで待つ
kubectl wait --for=condition=available deployment \
  -l app.kubernetes.io/name=external-secrets \
  -n external-secrets --timeout=300s
```

### 8. root Application デプロイ (App of Apps)

```bash
kubectl apply -f argocd/applications/root.yaml
```

root が `argocd/applications/` 内の全 Application を自動デプロイ:
- `infra` → ClusterSecretStore, ExternalSecret (Secret Manager → K8s Secret 同期)
- `echo-dev` → echo service dev 環境 (自動同期)
- `echo-prod` → echo service prod 環境 (手動同期)

### 9. ArgoCD 再起動 & 確認

```bash
# Secret 反映のため Dex と Server を再起動
kubectl rollout restart deployment argocd-dex-server argocd-server -n argocd
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=120s

# ArgoCD UI にアクセス
kubectl port-forward svc/argocd-server -n argocd 8443:443
# ブラウザで https://localhost:8443 を開き GitHub ログイン
```

## Teardown (全リソース削除)

### 1. ArgoCD Application 削除

```bash
kubectl delete -f argocd/applications/root.yaml
kubectl delete -f argocd/bootstrap/external-secrets.yaml

kubectl delete -n argocd \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.6/manifests/install.yaml
kubectl delete namespace argocd
kubectl delete namespace external-secrets
kubectl delete namespace dev
kubectl delete namespace prod
```

### 2. GCP Secret Manager のシークレット削除

```bash
gcloud secrets delete argocd-github-client-id --quiet
gcloud secrets delete argocd-github-client-secret --quiet
```

### 3. Terraform destroy

```bash
cd terraform
terraform destroy
```

### 4. Terraform state バケット削除

```bash
gcloud storage rm -r gs://gke-practice-kyosu-tfstate
```

### 5. GCP プロジェクト削除 (オプション)

```bash
gcloud projects delete gke-practice-kyosu
```

全リソースが完全に削除されます。プロジェクト削除は30日間は復元可能です。
