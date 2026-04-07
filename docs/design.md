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
| ArgoCD | 3.3.3 |
| Kustomize | 5.8.1 |
| GKE (Kubernetes) | 1.33 (stable channel) |
| Base image | gcr.io/distroless/static-debian12:nonroot |
| actions/checkout | v6 (コミットハッシュ固定) |
| actions/setup-go | v6 (コミットハッシュ固定) |
| google-github-actions/auth | v3 (コミットハッシュ固定) |
| google-github-actions/setup-gcloud | v3 (コミットハッシュ固定) |
| hashicorp/setup-terraform | v3 (コミットハッシュ固定) |
| actions/github-script | v7 (コミットハッシュ固定) |

## Repository Structure

```
gke-practice/
├── go/
│   └── services/
│       └── api/                # 1つ目のサービス（将来 go/services/worker/ 等を追加）
│           ├── main.go
│           ├── go.mod
│           └── Dockerfile
├── k8s/
│   └── api/                    # アプリごとにディレクトリを分離
│       ├── base/
│       │   ├── deployment.yaml
│       │   ├── service.yaml
│       │   └── kustomization.yaml
│       └── overlays/
│           ├── dev/
│           │   └── kustomization.yaml
│           └── prod/
│               └── kustomization.yaml
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── backend.tf
│   └── terraform.tfvars
├── argocd/
│   ├── install.yaml
│   └── applications/
│       ├── echo-dev.yaml
│       └── echo-prod.yaml
├── .github/
│   └── workflows/
│       ├── app-ci.yaml         # go/services/ 配下の変更サービスを動的検知、1ワークフローで全サービス対応
│       └── terraform.yaml
└── docs/
```

## Application

### Endpoints

| Method | Path | Response | Purpose |
|---|---|---|---|
| GET | /health | `{"status": "ok"}` | liveness/readiness probe |
| GET | /api/hello | `{"message": "hello", "hostname": "<pod-name>"}` | LB分散確認 |
| GET | /metrics | Prometheus format | Phase 2 監視用 |

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
| IAM | GitHub Actions 用 SA (Workload Identity Federation) |

### Configuration

- Backend: GCS remote state
- Provider: hashicorp/google 7.26.0

## Kubernetes Manifests

### Base Resources

- **Deployment**: Go API, resource requests/limits, probes
  - requests: cpu 50m, memory 64Mi
  - limits: cpu 200m, memory 128Mi
  - livenessProbe: httpGet /health
  - readinessProbe: httpGet /health
- **Service**: ClusterIP
- **Ingress**: L7 routing (Phase 2)
- **HPA**: CPU-based autoscaling (Phase 2)
- **NetworkPolicy**: Pod間通信制御 (Phase 2)

### Overlays

| Environment | Namespace | Replicas | Notes |
|---|---|---|---|
| dev | dev | 1 | 自動同期 |
| prod | prod | 2 | 手動同期 |

### Kustomize

- base/ に共通リソース
- overlays/ で環境ごとの差分 (namespace, replicas, image tag)

## CI/CD

### GitHub Actions セキュリティ方針

[Mercari GitHub Actions ガイドライン](https://engineering.mercari.com/blog/entry/20230609-github-actions-guideline/) に準拠:

- **アクション固定**: すべてのサードパーティアクションはフルコミットハッシュで固定（`uses: actions/checkout@<sha> # v6`）
- **最小権限**: permissions はワークフローレベルではなく job 単位で必要最小限を設定
- **インジェクション対策**: `${{ }}` 式を `run:` に直接展開せず、`env:` 経由で渡す
- **自動更新**: Dependabot でハッシュ固定されたアクションのバージョンを自動更新
- **認証**: Workload Identity Federation (keyless) を使用、PAT/SSH key は不使用

### GitHub Actions: app-ci.yaml

Trigger: `push` on `go/services/**`

Jobs（動的マトリクス）:
1. **detect**: git diff で `go/services/` 配下の変更サービスを検出、マトリクスとして出力
2. **test**: 変更アプリごとに Go test（permissions: contents read のみ）
3. **build-and-push**: 変更アプリごとに Docker build → Artifact Registry push → dev image tag 更新（permissions: contents write, id-token write）

アプリ追加時にワークフロー修正不要。`go/services/{new-app}/` を追加するだけで自動検知。

### GitHub Actions: terraform.yaml

Trigger: `push` / `pull_request` on `terraform/**`

Jobs（分割）:
- **plan** (PR時): terraform fmt -check → terraform plan → PR コメント（permissions: contents read, id-token write, pull-requests write）
- **apply** (main マージ後): terraform apply + 手動承認（permissions: contents read, id-token write）

### ArgoCD

| Setting | dev | prod |
|---|---|---|
| Sync Policy | 自動 | 手動 |
| Source Path | k8s/echo/overlays/dev | k8s/echo/overlays/prod |
| Self-heal | 有効 | 有効 |
| Prune | 有効 | 無効 |

## Authentication

- **GitHub Actions → GCP**: Workload Identity Federation (keyless)
- **Pod → GCP**: Workload Identity
- **ArgoCD UI**: kubectl port-forward (LB 不要)

## Phases

### Phase 1: 基盤構築
1. Terraform で GCP リソース構築 (VPC, GKE, Artifact Registry, GCS)
2. Go アプリ作成 + Dockerfile
3. GitHub Actions で CI (test → build → push)
4. K8s マニフェスト作成 (Kustomize base + overlays)
5. ArgoCD インストール + Application 設定
6. dev 環境への自動デプロイ確認

### Phase 2: 運用品質向上
7. NetworkPolicy (Pod間通信制御)
8. RBAC + ServiceAccount
9. Workload Identity (GCPサービス連携)
10. HPA (オートスケーリング)
11. PodDisruptionBudget

### Phase 3: 監視 (ノード追加後)
12. Prometheus + Grafana 導入
13. /metrics エンドポイント活用
14. Loki (ログ集約) — オプション

### Phase 4: セキュリティ強化 — オプション
15. Trivy (イメージスキャン CI 統合)
16. OPA/Gatekeeper (ポリシー適用)

## Cost Estimate (Phase 1)

| Item | Monthly (100h) | Always-on |
|---|---|---|
| e2-medium × 1 | ~$3.5 | ~$25 |
| Disk 10GB | ~$0.4 | ~$0.4 |
| Artifact Registry | ~$0 (少量) | ~$0 |
| GCS (state) | ~$0 | ~$0 |
| **Total** | **~$4** | **~$26** |

LB を使わない前提。kubectl port-forward で代用。
