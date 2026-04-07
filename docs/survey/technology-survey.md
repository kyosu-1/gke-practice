# Phase 1 要素技術サーベイ

実装計画で使用する各技術について、仕組み・ベストプラクティス・参考URLをまとめる。

---

## 目次

1. [GKE (Google Kubernetes Engine)](#1-gke-google-kubernetes-engine)
2. [Terraform (GCS Backend / GKE プロビジョニング)](#2-terraform)
3. [Go HTTP サーバー & Graceful Shutdown](#3-go-http-サーバー--graceful-shutdown)
4. [Docker マルチステージビルド & Distroless](#4-docker-マルチステージビルド--distroless)
5. [Kustomize](#5-kustomize)
6. [ArgoCD (GitOps CD)](#6-argocd-gitops-cd)
7. [GitHub Actions CI](#7-github-actions-ci)
8. [Workload Identity Federation](#8-workload-identity-federation)
9. [GCP Artifact Registry](#9-gcp-artifact-registry)
10. [Kubernetes リソース (Probes / HPA)](#10-kubernetes-リソース)
11. [Dependabot](#11-dependabot)

---

## 1. GKE (Google Kubernetes Engine)

### 概要

Google Cloud が提供するマネージド Kubernetes サービス。コントロールプレーンの管理が不要で、ノードプールのオートスケーリングやアップグレードも自動化できる。

### 本プロジェクトでの使い方

- **Standard モード** を使用（Autopilot ではなく、ノードプールを明示管理）
- **VPC-native クラスタ**: Pod / Service に GCP VPC の secondary IP range を割り当て、GCP ネイティブのルーティングを利用
- **Workload Identity**: Pod が GCP サービスアカウントとして認証可能
- **Release Channel**: STABLE チャネルで自動アップグレード

### VPC-native クラスタの仕組み

従来の routes-based クラスタと異なり、Pod IP が VPC の alias IP range として割り当てられる。これにより:

- Pod から GCP サービスへの直接通信が可能（NAT 不要）
- ファイアウォールルールで Pod IP range を直接指定可能
- GCP Load Balancer が Pod IP に直接ルーティング可能（NEG 連携）

```
VPC (Custom)
├── Subnet: 10.0.0.0/24      ← Node IP
├── Secondary: 10.1.0.0/16   ← Pod IP (alias IP)
└── Secondary: 10.2.0.0/20   ← Service IP (alias IP)
```

### ベストプラクティス

- `remove_default_node_pool = true` でデフォルトプールを削除し、カスタムプールを別リソースで管理する（ライフサイクルを分離）
- `deletion_protection = false` は学習用のみ。本番では true にする
- ノードの `oauth_scopes` は `cloud-platform` に統一し、IAM で細かく制御する

### 参考URL

- [VPC-native クラスタの作成](https://cloud.google.com/kubernetes-engine/docs/how-to/alias-ips)
- [VPC-native クラスタの概念](https://cloud.google.com/kubernetes-engine/docs/concepts/alias-ips)
- [Workload Identity](https://cloud.google.com/kubernetes-engine/docs/how-to/workload-identity)

---

## 2. Terraform

### 概要

HashiCorp が提供する IaC (Infrastructure as Code) ツール。HCL で宣言的にインフラを定義し、`plan` → `apply` のワークフローで変更を適用する。

### 本プロジェクトでの使い方

- **GCS Backend**: tfstate を GCS バケットに保存（チーム開発・CI/CD 対応）
- **google provider**: VPC, GKE, Artifact Registry, IAM, Workload Identity Federation を一括管理

### GCS Backend の仕組み

```hcl
backend "gcs" {
  bucket = "project-tfstate"
  prefix = "gke-practice"
}
```

- tfstate ファイルを GCS に保存し、ロック機能で同時実行を防止
- Backend 用バケット自体は Terraform 外で作成する必要がある（鶏と卵問題）
- `prefix` でプロジェクト単位に state を分離

### GKE クラスタの Terraform 管理

`google_container_cluster` と `google_container_node_pool` を分離するのがベストプラクティス:

```
google_container_cluster (remove_default_node_pool = true)
└── google_container_node_pool (autoscaling, machine_type, etc.)
```

分離する理由:
- クラスタとノードプールのライフサイクルが異なる
- ノードプールの変更でクラスタ全体が再作成されるのを防止
- 複数のノードプールを独立して管理可能

### ベストプラクティス

- `terraform fmt -check` と `terraform validate` を CI に組み込む
- PR で `plan` 結果をコメントし、レビューしてから `apply`
- `required_version` と `required_providers` でバージョンを固定

### 参考URL

- [Terraform GCS Backend](https://developer.hashicorp.com/terraform/language/backend/gcs)
- [google_container_cluster リソース](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/container_cluster)

---

## 3. Go HTTP サーバー & Graceful Shutdown

### 概要

Go 標準ライブラリの `net/http` でシンプルな HTTP サーバーを構築する。Kubernetes 環境では Graceful Shutdown が必須。

### Graceful Shutdown の仕組み

```go
// 1. SIGTERM シグナルを待機
quit := make(chan os.Signal, 1)
signal.Notify(quit, syscall.SIGTERM, syscall.SIGINT)
<-quit

// 2. 新規接続の受付を停止し、既存リクエストの完了を待つ
ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
defer cancel()
srv.Shutdown(ctx)
```

Kubernetes が Pod を停止する流れ:
1. Pod に SIGTERM を送信
2. `terminationGracePeriodSeconds`（デフォルト30秒）待機
3. タイムアウト後に SIGKILL

`srv.Shutdown()` は:
- リスナーを閉じて新規接続を拒否
- 処理中のリクエストが完了するのを待機
- context のタイムアウトで強制終了

### ベストプラクティス

- `Shutdown` のタイムアウトは `terminationGracePeriodSeconds` より短く設定する
- `ListenAndServe` のエラーハンドリングで `http.ErrServerClosed` を正常終了として扱う
- readinessProbe が先に fail するよう、preStop hook の `sleep` を入れる場合もある

### 参考URL

- [net/http Server.Shutdown](https://pkg.go.dev/net/http#Server.Shutdown)

---

## 4. Docker マルチステージビルド & Distroless

### 概要

マルチステージビルドでビルド環境と実行環境を分離し、Distroless イメージで最小限の実行環境を実現する。

### マルチステージビルドの仕組み

```dockerfile
# Stage 1: ビルド環境（Go SDK, ビルドツール含む）
FROM golang:1.26 AS builder
WORKDIR /app
COPY go.mod ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o server .

# Stage 2: 実行環境（バイナリのみ）
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /app/server /server
ENTRYPOINT ["/server"]
```

- Stage 1 のイメージは最終イメージに含まれない
- Go のように static binary を生成できる言語と特に相性が良い

### Distroless イメージとは

Google が提供する最小限のコンテナイメージ。シェル、パッケージマネージャ、OS ユーティリティが一切含まれない。

| イメージ | 用途 |
|---|---|
| `distroless/static` | Go など static binary 向け |
| `distroless/base` | C ライブラリが必要なアプリ向け |
| `distroless/java` | Java アプリ向け |

`:nonroot` タグは非 root ユーザー（UID 65534）で実行する。

### ベストプラクティス

- `CGO_ENABLED=0` で static binary を生成し、`distroless/static` を使う
- `--platform linux/amd64` を指定して GKE のアーキテクチャに合わせる（M1/M2 Mac 対策）
- `:nonroot` タグ + `USER nonroot:nonroot` で非 root 実行を明示

### 参考URL

- [Docker マルチステージビルド](https://docs.docker.com/build/building/multi-stage/)
- [Distroless イメージ](https://github.com/GoogleContainerTools/distroless)

---

## 5. Kustomize

### 概要

Kubernetes マニフェストのカスタマイズツール。テンプレートを使わず、base マニフェストに overlay（パッチ）を適用して環境ごとの差分を管理する。

### 構造

```
k8s/
├── base/                    ← 共通リソース定義
│   ├── deployment.yaml
│   ├── service.yaml
│   └── kustomization.yaml
└── overlays/
    ├── dev/                 ← dev 固有の設定
    │   └── kustomization.yaml
    └── prod/                ← prod 固有の設定
        └── kustomization.yaml
```

### images トランスフォーマー

Helm と異なり、テンプレート変数を使わずにイメージを差し替えられる:

```yaml
# overlays/dev/kustomization.yaml
images:
  - name: gke-practice           # base の deployment.yaml で指定した名前
    newName: asia-northeast1-docker.pkg.dev/PROJECT/repo/api
    newTag: abc1234               # CI が git SHA で更新
```

CI での更新コマンド:

```bash
kustomize edit set image gke-practice=REGISTRY/api:${GIT_SHA}
```

### ベストプラクティス

- base にはプレースホルダー的なイメージ名（`gke-practice`）を使い、overlay で実イメージに差し替え
- namespace は overlay の `namespace:` フィールドで一括設定
- replicas も overlay の `replicas:` フィールドで変更可能（パッチ不要）

### 参考URL

- [Kustomization リファレンス](https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/)
- [images フィールド](https://kubectl.docs.kubernetes.io/references/kustomize/kustomization/images/)

---

## 6. ArgoCD (GitOps CD)

### 概要

Kubernetes 向けの GitOps CD ツール。Git リポジトリの状態を「あるべき姿」として、クラスタの状態を自動的に同期する。

### GitOps の流れ

```
Developer → git push → GitHub → ArgoCD が検知 → K8s クラスタに同期
```

ArgoCD は:
1. Git リポジトリを定期的にポーリング（デフォルト3分間隔）
2. Git の状態とクラスタの状態を比較
3. 差分があれば同期（自動 or 手動）

### Application CRD

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: gke-practice-dev
  namespace: argocd
spec:
  source:
    repoURL: https://github.com/owner/repo.git
    targetRevision: main
    path: k8s/overlays/dev         # Kustomize ディレクトリ
  destination:
    server: https://kubernetes.default.svc
    namespace: dev
  syncPolicy:
    automated:
      prune: true      # Git から削除されたリソースをクラスタからも削除
      selfHeal: true    # クラスタ上の手動変更を Git の状態に戻す
```

### Sync Policy の設計

| 設定 | dev | prod | 理由 |
|---|---|---|---|
| automated | Yes | Yes（手動も可） | dev は素早く反映、prod は慎重に |
| prune | Yes | No | prod で意図しない削除を防止 |
| selfHeal | Yes | Yes | ドリフト防止は両環境で有効 |

### ベストプラクティス

- CI がイメージタグを kustomization.yaml に書き込み → ArgoCD が同期、という分離
- ArgoCD 自体は `kubectl apply` で直接インストール（ArgoCD で ArgoCD を管理しない）
- UI アクセスは `kubectl port-forward` で十分（学習用途なら LB 不要）

### 参考URL

- [ArgoCD Automated Sync Policy](https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/)

---

## 7. GitHub Actions CI

### 概要

GitHub ネイティブの CI/CD プラットフォーム。リポジトリのイベント（push, PR）をトリガーにワークフローを実行する。

### 本プロジェクトの CI 設計

**App CI** (`app-ci.yaml`): `app/**` の変更で発火

```
test (Go test) → build-and-push (Docker build → AR push → tag update → git push)
```

**Terraform CI** (`terraform.yaml`): `terraform/**` の変更で発火

```
PR: fmt check → plan → PR コメント
main push: init → apply (environment: production で手動承認)
```

### Actions のバージョン固定

サプライチェーン攻撃対策として、コミットハッシュで固定する:

```yaml
# Bad: タグは上書き可能
uses: actions/checkout@v6

# Good: コミットハッシュで固定（タグ上書き不可）
uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6
```

Dependabot がハッシュの更新 PR を自動作成してくれる。

### permissions の最小化

```yaml
permissions:
  contents: read        # リポジトリの読み取り
  id-token: write       # Workload Identity Federation 用の OIDC トークン
  pull-requests: write  # PR コメント用（Terraform plan 結果）
```

`id-token: write` が Workload Identity Federation の鍵。これにより GitHub が OIDC トークンを発行し、GCP が検証する。

### ベストプラクティス

- `paths` フィルターで不要な実行を避ける
- `needs` でジョブ間の依存を明示（test が通ってから build）
- Terraform の `apply` は `environment: production` で手動承認ゲートを設ける

### 参考URL

- [google-github-actions/auth](https://github.com/google-github-actions/auth)

---

## 8. Workload Identity Federation

### 概要

外部の ID プロバイダー（GitHub, GitLab, AWS 等）が発行するトークンを GCP のサービスアカウントにマッピングする仕組み。**サービスアカウントキー（JSON キー）が不要**になる。

### 仕組み

```
GitHub Actions                           GCP
    │                                     │
    ├─ OIDC トークン発行 ──────────────→ Workload Identity Pool
    │  (iss: token.actions.githubusercontent.com)  │
    │                                     ├─ Provider が検証
    │                                     │  (attribute_condition で repo 制限)
    │                                     ├─ SA にマッピング
    │                                     │
    │ ←──── GCP アクセストークン ─────────┘
    │
    └─ gcloud / docker push / kubectl 実行
```

### Terraform での構成

```
Workload Identity Pool
└── Provider (OIDC, issuer = token.actions.githubusercontent.com)
    └── attribute_condition: "assertion.repository == 'owner/repo'"

Service Account (github-actions)
├── roles/artifactregistry.writer  ← Docker push
├── roles/container.developer      ← kubectl
└── workloadIdentityUser           ← WIF からの認証許可
```

### attribute_condition の重要性

`attribute_condition` がないと、任意の GitHub リポジトリから GCP リソースにアクセスできてしまう。必ずリポジトリを制限する:

```hcl
attribute_condition = "assertion.repository == \"owner/repo\""
```

### ベストプラクティス

- JSON キーは使わない。WIF を使う
- `attribute_condition` で必ずリポジトリを制限
- SA の権限は最小限に（writer, developer など）
- Pool / Provider の命名は用途がわかるようにする

### 参考URL

- [Workload Identity Federation (CI/CD)](https://cloud.google.com/iam/docs/workload-identity-federation-with-deployment-pipelines)
- [google-github-actions/auth](https://github.com/google-github-actions/auth)

---

## 9. GCP Artifact Registry

### 概要

GCP のコンテナイメージ・パッケージ管理サービス。旧 Container Registry (GCR) の後継。

### 本プロジェクトでの使い方

```
REGION-docker.pkg.dev/PROJECT_ID/REPOSITORY/IMAGE:TAG
asia-northeast1-docker.pkg.dev/my-project/gke-practice/api:abc1234
```

### Docker 認証

```bash
# gcloud で Docker の認証ヘルパーを設定
gcloud auth configure-docker asia-northeast1-docker.pkg.dev --quiet
```

GitHub Actions では WIF 認証後にこのコマンドを実行するだけで push 可能。

### ベストプラクティス

- リポジトリは用途・チームごとに分ける
- イメージタグは git SHA の先頭7文字を使う（一意かつトレーサブル）
- `latest` タグはデプロイには使わない（どのバージョンか追跡不能）

### 参考URL

- [Artifact Registry Docker リポジトリ](https://cloud.google.com/artifact-registry/docs/docker)

---

## 10. Kubernetes リソース

### Liveness / Readiness Probe

**Liveness Probe**: コンテナが生きているか確認。失敗するとコンテナを再起動。

**Readiness Probe**: トラフィックを受ける準備ができているか確認。失敗すると Service のエンドポイントから除外。

```yaml
livenessProbe:
  httpGet:
    path: /health
    port: 8080
  initialDelaySeconds: 5    # 起動後5秒待ってからチェック開始
  periodSeconds: 10         # 10秒ごとにチェック

readinessProbe:
  httpGet:
    path: /health
    port: 8080
  initialDelaySeconds: 3
  periodSeconds: 5
```

### Resource Requests / Limits

```yaml
resources:
  requests:          # スケジューラが確保する最低リソース
    cpu: 50m         # 0.05 vCPU
    memory: 64Mi
  limits:            # 超過時の挙動: CPU=スロットリング, Memory=OOMKill
    cpu: 200m
    memory: 128Mi
```

- `requests` はスケジューリングとHPAの基準
- `limits` はリソース使用の上限

### HPA (Horizontal Pod Autoscaler)

CPU 使用率に基づいて Pod 数を自動調整（Phase 2）:

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: gke-practice
  minReplicas: 1
  maxReplicas: 5
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
```

### 参考URL

- [Liveness / Readiness Probe](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/)
- [HPA Walkthrough](https://kubernetes.io/docs/tasks/run-application/horizontal-pod-autoscale-walkthrough/)

---

## 11. Dependabot

### 概要

GitHub が提供する依存関係の自動更新ツール。設定ファイルを置くだけで、更新の PR を自動作成する。

### 本プロジェクトでの使い方

GitHub Actions のバージョンをコミットハッシュ固定しているため、新バージョンが出たら Dependabot が PR を作る:

```yaml
# .github/dependabot.yml
version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
```

### ベストプラクティス

- `github-actions` エコシステムで Actions の自動更新
- 週次スケジュールで過度な PR を防止
- コミットハッシュ固定 + Dependabot の組み合わせが、セキュリティと最新化のバランスが最も良い

### 参考URL

- [Dependabot で Actions を最新に保つ](https://docs.github.com/en/code-security/dependabot/working-with-dependabot/keeping-your-actions-up-to-date-with-dependabot)

---

## 全体アーキテクチャ図

```
┌─────────────┐     push      ┌──────────────────┐
│  Developer  │──────────────→│  GitHub (main)   │
└─────────────┘               └──────┬───────────┘
                                     │
                    ┌────────────────┼────────────────┐
                    │ app/**         │ terraform/**   │
                    ▼                ▼                │
              ┌───────────┐   ┌───────────┐          │
              │ App CI    │   │ TF CI     │          │
              │ test→build│   │ plan→apply│          │
              └─────┬─────┘   └───────────┘          │
                    │                                 │
                    ▼                                 │
         ┌──────────────────┐                        │
         │ Artifact Registry│                        │
         │ (Docker images)  │                        │
         └──────────────────┘                        │
                    │                                 │
                    │ kustomize edit set image        │
                    ▼                                 │
         ┌──────────────────┐                        │
         │ k8s/overlays/dev │  ← git push (tag更新)  │
         │ kustomization.yaml                        │
         └────────┬─────────┘                        │
                  │ ArgoCD が検知                     │
                  ▼                                  │
         ┌──────────────────┐     Terraform          │
         │   GKE Cluster    │ ←──────────────────────┘
         │  ┌──────┐        │
         │  │ Pod  │ dev ns │
         │  └──────┘        │
         └──────────────────┘
```

---

## まとめ: 学習のポイント

| カテゴリ | 学ぶべきこと |
|---|---|
| **IaC** | Terraform の state 管理、plan/apply フロー、リソース分離 |
| **コンテナ** | マルチステージビルド、Distroless、非 root 実行 |
| **K8s マニフェスト管理** | Kustomize の base/overlay パターン、テンプレートレスなカスタマイズ |
| **GitOps** | CI（ビルド・プッシュ）と CD（同期・デプロイ）の責務分離 |
| **認証** | WIF によるキーレス認証、SA 権限の最小化 |
| **CI/CD** | GitHub Actions の paths フィルタ、permissions 最小化、ハッシュ固定 |
| **運用** | Probe 設計、Graceful Shutdown、リソース制御 |
