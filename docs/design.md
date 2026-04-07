# GKE Practice - Design Spec

## Overview

Kubernetes, GKE, Terraform のベストプラクティスを実践的に学ぶための学習プロジェクト。
シンプルな Go HTTP API を題材に、インフラ構築から GitOps CD までの一連のフローを構築する。

## Tool Versions

| Tool | Version |
|---|---|
| Go | 1.26.1 |
| Terraform | 1.14.8 |
| terraform-provider-google | 7.26.0 |
| ArgoCD | 3.3.6 |
| ArgoCD Image Updater | 0.16.0 (Helm chart 0.12.1) |
| External Secrets Operator | 2.2.0 |
| Kustomize | 5.8.1 |
| GKE (Kubernetes) | 1.33 (stable channel) |
| Base image | gcr.io/distroless/static-debian12:nonroot |
| actions/checkout | v6 (コミットハッシュ固定) |
| actions/setup-go | v6 (コミットハッシュ固定) |
| google-github-actions/auth | v3 (コミットハッシュ固定) |
| hashicorp/setup-terraform | v3 (コミットハッシュ固定) |
| actions/github-script | v7 (コミットハッシュ固定) |

## Repository Structure

```
gke-practice/
├── go/
│   └── services/
│       └── echo/                   # サービス（将来 go/services/worker/ 等を追加）
│           ├── main.go
│           ├── main_test.go
│           ├── go.mod
│           └── Dockerfile
├── k8s/
│   ├── services/
│   │   └── echo/                   # サービスごとに分離
│   │       ├── base/
│   │       │   ├── deployment.yaml
│   │       │   ├── service.yaml
│   │       │   └── kustomization.yaml
│   │       └── overlays/
│   │           ├── dev/
│   │           │   └── kustomization.yaml
│   │           └── prod/
│   │               └── kustomization.yaml
│   └── infra/                      # クラスタインフラ
│       ├── secret-store.yaml           ClusterSecretStore (GCP Secret Manager)
│       ├── argocd-github-oauth.yaml    ExternalSecret (ArgoCD OAuth)
│       ├── image-updater-github-app.yaml  ExternalSecret (Image Updater GitHub App)
│       └── image-updater-gcp-auth.yaml    ConfigMap (AR 認証スクリプト)
├── terraform/
│   ├── main.tf                     # VPC, GKE, AR, WIF, IAM, Secret Manager, ESO SA, Image Updater SA
│   ├── variables.tf
│   ├── outputs.tf
│   ├── backend.tf
│   └── terraform.tfvars
├── argocd/
│   ├── install.yaml                # ブートストラップ手順ドキュメント
│   ├── applications/               # root が自動管理 (App of Apps)
│   │   ├── root.yaml
│   │   ├── infra.yaml
│   │   ├── echo-dev.yaml
│   │   └── echo-prod.yaml
│   ├── bootstrap/                  # 手動で順番に適用（依存関係あり）
│   │   ├── external-secrets.yaml       ESO Helm chart
│   │   └── image-updater.yaml          Image Updater Helm chart
│   └── config/                     # ArgoCD 自身の設定（手動 apply）
│       ├── argocd-cm-patch.yaml        GitHub OAuth (Dex) 設定
│       └── argocd-rbac-cm-patch.yaml   RBAC 設定
├── .github/
│   ├── workflows/
│   │   ├── app-ci.yaml             # 動的マトリクス CI（build & push のみ）
│   │   └── terraform.yaml          # Terraform plan/apply
│   └── dependabot.yml              # GitHub Actions 自動更新
└── docs/
```

## Application

### Endpoints

| Method | Path | Response | Purpose |
|---|---|---|---|
| GET | /health | `{"status": "ok"}` | liveness/readiness probe |
| GET | /api/hello | `{"message": "hello", "hostname": "<pod>", "version": "v1"}` | LB分散確認 |

### Tech Stack

- Go 1.26, net/http (標準ライブラリのみ)
- マルチステージビルド (builder → distroless)
- Graceful shutdown (SIGTERM handling)

## Terraform Resources

### GCP Resources

| Resource | Details |
|---|---|
| VPC | Custom VPC, asia-northeast1 |
| Subnet | 10.0.0.0/24, Pod range: 10.1.0.0/16, Service range: 10.2.0.0/20 |
| GKE Cluster | Standard mode, asia-northeast1-a, VPC-native, Workload Identity |
| Node Pool | e2-medium, autoscaling 1-3 |
| Artifact Registry | Docker repository |
| GCS Bucket | Terraform remote state |
| Secret Manager API | シークレット管理 |
| IAM - github-actions SA | Workload Identity Federation, AR writer, GKE developer |
| IAM - external-secrets SA | Secret Manager accessor, Workload Identity |
| IAM - argocd-image-updater SA | AR reader, Workload Identity |

## Kubernetes Manifests

### Base Resources (per service)

- **Deployment**: resource requests/limits, liveness/readiness probes
- **Service**: ClusterIP

### Overlays

| Environment | Namespace | Replicas | Notes |
|---|---|---|---|
| dev | dev | 1 | Image Updater が自動でイメージタグ更新 |
| prod | prod | 2 | 手動同期 |

### Infrastructure (k8s/infra/)

- **ClusterSecretStore**: GCP Secret Manager への接続設定 (Workload Identity 認証)
- **ExternalSecret**: ArgoCD GitHub OAuth, Image Updater GitHub App の認証情報を同期
- **ConfigMap**: Image Updater の GCP Artifact Registry 認証スクリプト

## CI/CD

### 全体フロー

```
Developer → git push → GitHub Actions (CI)
                            ├── detect: 変更サービス検出
                            ├── test: Go test
                            └── build-and-push: Docker build → AR push
                                                        ↓
                        ArgoCD Image Updater (CD)
                            ├── AR を polling (2分間隔)
                            ├── 新しいタグ検知
                            ├── kustomization.yaml 更新
                            └── git commit & push (GitHub App 認証)
                                                        ↓
                        ArgoCD (Deploy)
                            ├── Git 変更検知
                            └── K8s に自動デプロイ
```

### GitHub Actions セキュリティ方針

[Mercari GitHub Actions ガイドライン](https://engineering.mercari.com/blog/entry/20230609-github-actions-guideline/) に準拠:

- **アクション固定**: すべてのサードパーティアクションはフルコミットハッシュで固定
- **最小権限**: permissions は job 単位で必要最小限を設定
- **インジェクション対策**: `${{ }}` 式を `run:` に直接展開せず、`env:` 経由で渡す
- **自動更新**: Dependabot でハッシュ固定されたアクションのバージョンを自動更新
- **認証**: Workload Identity Federation (keyless) を使用、PAT/SSH key は不使用

### GitHub Actions: app-ci.yaml

Trigger: `push` on `go/services/**`

Jobs（動的マトリクス）:
1. **detect**: git diff で `go/services/` 配下の変更サービスを検出
2. **test**: 変更サービスごとに Go test（permissions: contents read のみ）
3. **build-and-push**: Docker build → Artifact Registry push（permissions: contents read, id-token write）

CI はビルド & プッシュのみ。イメージタグ更新は Image Updater が担当（責務分離）。
サービス追加時にワークフロー修正不要。

### GitHub Actions: terraform.yaml

Trigger: `push` / `pull_request` on `terraform/**`

- **plan** (PR時): terraform fmt -check → terraform plan → PR コメント
- **apply** (main マージ後): terraform apply + 手動承認 (environment: production)

### ArgoCD Image Updater

- Artifact Registry を 2分間隔で polling
- 新しいタグ検知時に kustomization.yaml を更新
- **git write-back** 方式（Git が Single Source of Truth を維持）
- GitHub App 認証（短命トークン、リポジトリ単位の権限）
- GCP Artifact Registry 認証は Workload Identity 経由

### ArgoCD (App of Apps)

| Application | 管理対象 | Sync Policy |
|---|---|---|
| root | argocd/applications/ 内の全 Application | 自動 |
| infra | k8s/infra/ (SecretStore, ExternalSecret) | 自動 + ServerSideApply |
| echo-dev | k8s/services/echo/overlays/dev | 自動 + Image Updater |
| echo-prod | k8s/services/echo/overlays/prod | 自動 (prune 無効) |
| external-secrets | ESO Helm chart (bootstrap) | 自動 |
| argocd-image-updater | Image Updater Helm chart (bootstrap) | 自動 |

### ブートストラップ順序

```
1. ArgoCD install (kubectl apply)     ← 手動
2. ArgoCD config (OAuth, RBAC)        ← 手動
3. ESO (bootstrap/external-secrets)   ← 手動 (CRD 依存)
4. Image Updater (bootstrap/)         ← 手動
5. root Application                   ← 手動 (以降自動)
   └→ infra, echo-dev, echo-prod      ← ArgoCD 自動管理
```

## Authentication & Secrets

| 認証フロー | 方式 |
|---|---|
| GitHub Actions → GCP | Workload Identity Federation (keyless) |
| ESO → GCP Secret Manager | Workload Identity |
| Image Updater → Artifact Registry | Workload Identity + メタデータサーバー |
| Image Updater → GitHub (git push) | GitHub App (短命トークン) |
| ArgoCD UI ログイン | GitHub OAuth (Dex) |
| ArgoCD UI アクセス | kubectl port-forward (LB 不要) |

### シークレット管理

```
GCP Secret Manager (source of truth)
  ├── argocd-github-client-id/secret     → ESO → K8s Secret → ArgoCD Dex
  ├── argocd-image-updater-github-app-*  → ESO → K8s Secret → Image Updater
  └── (将来追加するシークレットも同じパターン)
```

PAT、SSH key、長寿命クレデンシャルは一切使用しない。

## Phases

### Phase 1: 基盤構築 (完了)
1. Terraform で GCP リソース構築 (VPC, GKE, Artifact Registry, GCS, IAM)
2. Go echo サービス作成 + Dockerfile
3. GitHub Actions CI (動的マトリクス、コミットハッシュ固定)
4. K8s マニフェスト作成 (Kustomize base + overlays)
5. ArgoCD (App of Apps パターン) + GitHub OAuth
6. External Secrets Operator + GCP Secret Manager
7. ArgoCD Image Updater (GitHub App 認証、git write-back)
8. Dependabot (GitHub Actions 自動更新)

### Phase 2: 運用品質向上
- NetworkPolicy (Pod間通信制御)
- RBAC + ServiceAccount
- HPA (オートスケーリング)
- PodDisruptionBudget

### Phase 3: 監視
- Prometheus + Grafana 導入
- /metrics エンドポイント
- Loki (ログ集約) — オプション

### Phase 4: セキュリティ強化 — オプション
- Trivy (イメージスキャン CI 統合)
- OPA/Gatekeeper (ポリシー適用)

## Cost Estimate (Phase 1)

| Item | Monthly (100h) | Always-on |
|---|---|---|
| e2-medium × 1 | ~$3.5 | ~$25 |
| Disk 10GB | ~$0.4 | ~$0.4 |
| Artifact Registry | ~$0 (少量) | ~$0 |
| GCS (state) | ~$0 | ~$0 |
| **Total** | **~$4** | **~$26** |

LB を使わない前提。kubectl port-forward で代用。
