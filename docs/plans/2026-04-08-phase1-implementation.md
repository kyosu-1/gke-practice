# Phase 1: GKE Practice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Terraform → Go API → GitHub Actions CI → Kustomize → ArgoCD GitOps の一連のフローを構築する

**Architecture:** モノレポ構成で、go/services/{service}/ (Go API), terraform/ (GCPインフラ), k8s/{app}/ (Kustomize manifests), argocd/ (ArgoCD設定), .github/workflows/ (CI) を管理。GitHub Actions が go/ 配下の変更を動的検知し、変更アプリのみビルド・プッシュ。ArgoCD が k8s/ の変更を検知してクラスタに同期する。アプリ追加時は go/services/{new-service}/ + k8s/{new-app}/ を追加するだけ（CI修正不要）。

**Tech Stack:** Go 1.26, Terraform 1.14.8, GKE 1.33, ArgoCD 3.3.3, Kustomize 5.8.1, GitHub Actions

---

## File Map

| File | Responsibility |
|---|---|
| `go/services/echo/main.go` | HTTP server: /health, /api/hello, graceful shutdown |
| `go/services/echo/main_test.go` | Handler tests |
| `go/services/echo/go.mod` | Go module definition |
| `go/services/echo/Dockerfile` | Multi-stage build → distroless |
| `terraform/main.tf` | VPC, GKE, Artifact Registry, GCS, IAM, Workload Identity Federation |
| `terraform/variables.tf` | Input variables |
| `terraform/outputs.tf` | Cluster endpoint, registry URL etc. |
| `terraform/backend.tf` | GCS remote state config |
| `terraform/terraform.tfvars` | Variable values (gitignore対象外、秘密情報なし) |
| `k8s/echo/base/deployment.yaml` | Go API Deployment |
| `k8s/echo/base/service.yaml` | ClusterIP Service |
| `k8s/echo/base/kustomization.yaml` | Base kustomization |
| `k8s/echo/overlays/dev/kustomization.yaml` | dev overlay (namespace, replicas, image) |
| `k8s/echo/overlays/prod/kustomization.yaml` | prod overlay |
| `argocd/applications/echo-dev.yaml` | ArgoCD Application for api dev |
| `argocd/applications/echo-prod.yaml` | ArgoCD Application for api prod |
| `.github/workflows/app-ci.yaml` | 変更アプリ動的検知 → Go test → Docker build → push → tag update |
| `.github/workflows/terraform.yaml` | terraform plan/apply |
| `.github/dependabot.yml` | GitHub Actions の自動バージョン更新 |
| `.gitignore` | Terraform state, binaries etc. |

---

### Task 1: リポジトリ初期化

**Files:**
- Create: `.gitignore`
- Create: `README.md`

- [ ] **Step 1: git init + .gitignore 作成**

```bash
cd /Users/abe/ghq/github.com/kyosu-1/gke-practice
git init
```

```gitignore
# .gitignore
# Terraform
terraform/.terraform/
terraform/*.tfstate
terraform/*.tfstate.backup
terraform/.terraform.lock.hcl

# Go
go/*/server
*.exe

# OS
.DS_Store
```

- [ ] **Step 2: 初回コミット**

```bash
git add .gitignore docs/
git commit -m "init: add design doc and gitignore"
```

---

### Task 2: Go アプリケーション — テスト作成

**Files:**
- Create: `go/services/echo/go.mod`
- Create: `go/services/echo/main_test.go`

- [ ] **Step 1: Go module 初期化**

```bash
cd go/services/echo
go mod init github.com/kyosu-1/gke-practice/go/services/echo
```

`go/services/echo/go.mod`:
```go
module github.com/kyosu-1/gke-practice/go/services/echo

go 1.26
```

- [ ] **Step 2: テストを書く**

`go/services/echo/main_test.go`:
```go
package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestHealthHandler(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/health", nil)
	w := httptest.NewRecorder()

	healthHandler(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("expected status 200, got %d", w.Code)
	}

	var resp map[string]string
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}
	if resp["status"] != "ok" {
		t.Errorf("expected status ok, got %s", resp["status"])
	}
}

func TestHelloHandler(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/api/hello", nil)
	w := httptest.NewRecorder()

	helloHandler(w, req)

	if w.Code != http.StatusOK {
		t.Errorf("expected status 200, got %d", w.Code)
	}

	var resp map[string]string
	if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
		t.Fatalf("failed to decode response: %v", err)
	}
	if resp["message"] != "hello" {
		t.Errorf("expected message hello, got %s", resp["message"])
	}
	if resp["hostname"] == "" {
		t.Error("expected hostname to be non-empty")
	}
}
```

- [ ] **Step 3: テストが失敗することを確認**

```bash
cd go/services/echo && go test -v ./...
```

Expected: コンパイルエラー (`healthHandler` and `helloHandler` undefined)

---

### Task 3: Go アプリケーション — 実装

**Files:**
- Create: `go/services/echo/main.go`

- [ ] **Step 1: main.go を実装**

`go/services/echo/main.go`:
```go
package main

import (
	"context"
	"encoding/json"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func healthHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{"status": "ok"})
}

func helloHandler(w http.ResponseWriter, r *http.Request) {
	hostname, _ := os.Hostname()
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"message":  "hello",
		"hostname": hostname,
	})
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("/health", healthHandler)
	mux.HandleFunc("/api/hello", helloHandler)

	srv := &http.Server{
		Addr:    ":8080",
		Handler: mux,
	}

	go func() {
		log.Printf("server starting on :8080")
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Fatalf("server error: %v", err)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGTERM, syscall.SIGINT)
	<-quit
	log.Println("shutting down server...")

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(ctx); err != nil {
		log.Fatalf("server shutdown error: %v", err)
	}
	log.Println("server stopped")
}
```

- [ ] **Step 2: テスト実行 → パスすることを確認**

```bash
cd go/services/echo && go test -v ./...
```

Expected: `PASS`

- [ ] **Step 3: コミット**

```bash
git add go/services/echo/
git commit -m "feat: add Go HTTP API with health and hello endpoints"
```

---

### Task 4: Dockerfile

**Files:**
- Create: `go/services/echo/Dockerfile`

- [ ] **Step 1: マルチステージ Dockerfile 作成**

`go/services/echo/Dockerfile`:
```dockerfile
FROM golang:1.26 AS builder

WORKDIR /app
COPY go.mod ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o server .

FROM gcr.io/distroless/static-debian12:nonroot

COPY --from=builder /app/server /server

EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/server"]
```

- [ ] **Step 2: ローカルでビルド確認**

```bash
cd go/services/echo && docker build -t gke-practice-echo:local .
```

Expected: ビルド成功

- [ ] **Step 3: ローカルで動作確認**

```bash
docker run --rm -p 8080:8080 gke-practice-echo:local &
curl http://localhost:8080/health
curl http://localhost:8080/api/hello
docker stop $(docker ps -q --filter ancestor=gke-practice-echo:local)
```

Expected: `{"status":"ok"}` and `{"message":"hello","hostname":"<container-id>"}`

- [ ] **Step 4: コミット**

```bash
git add go/services/echo/Dockerfile
git commit -m "feat: add multi-stage Dockerfile with distroless"
```

---

### Task 5: Terraform — GCS Backend 用バケット作成（手動）

このステップは Terraform の外で行う。remote state 用バケットは Terraform 自身では管理できない（鶏と卵問題）。

- [ ] **Step 1: GCP プロジェクト確認・設定**

```bash
gcloud config set project <YOUR_PROJECT_ID>
gcloud services enable container.googleapis.com \
  artifactregistry.googleapis.com \
  iam.googleapis.com \
  compute.googleapis.com \
  cloudresourcemanager.googleapis.com
```

- [ ] **Step 2: GCS バケット作成**

```bash
gcloud storage buckets create gs://<YOUR_PROJECT_ID>-tfstate \
  --location=asia-northeast1 \
  --uniform-bucket-level-access
```

- [ ] **Step 3: バケット作成を確認**

```bash
gcloud storage buckets describe gs://<YOUR_PROJECT_ID>-tfstate
```

Expected: バケット情報が表示される

---

### Task 6: Terraform — インフラ定義

**Files:**
- Create: `terraform/backend.tf`
- Create: `terraform/variables.tf`
- Create: `terraform/main.tf`
- Create: `terraform/outputs.tf`
- Create: `terraform/terraform.tfvars`

- [ ] **Step 1: backend.tf**

`terraform/backend.tf`:
```hcl
terraform {
  required_version = ">= 1.14.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.26"
    }
  }

  backend "gcs" {
    bucket = "<YOUR_PROJECT_ID>-tfstate"
    prefix = "gke-practice"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
```

- [ ] **Step 2: variables.tf**

`terraform/variables.tf`:
```hcl
variable "project_id" {
  description = "GCP project ID"
  type        = string
}

variable "region" {
  description = "GCP region"
  type        = string
  default     = "asia-northeast1"
}

variable "zone" {
  description = "GCP zone"
  type        = string
  default     = "asia-northeast1-a"
}

variable "github_repo" {
  description = "GitHub repository (owner/repo format)"
  type        = string
  default     = "kyosu-1/gke-practice"
}
```

- [ ] **Step 3: main.tf — VPC**

`terraform/main.tf`:
```hcl
# ===== VPC =====
resource "google_compute_network" "main" {
  name                    = "gke-practice-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "main" {
  name          = "gke-practice-subnet"
  ip_cidr_range = "10.0.0.0/24"
  region        = var.region
  network       = google_compute_network.main.id

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.1.0.0/16"
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.2.0.0/20"
  }
}

# ===== GKE =====
resource "google_container_cluster" "main" {
  name     = "gke-practice"
  location = var.zone

  network    = google_compute_network.main.id
  subnetwork = google_compute_subnetwork.main.id

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  release_channel {
    channel = "STABLE"
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  # We manage the node pool separately
  remove_default_node_pool = true
  initial_node_count       = 1

  deletion_protection = false
}

resource "google_container_node_pool" "main" {
  name     = "default-pool"
  location = var.zone
  cluster  = google_container_cluster.main.name

  autoscaling {
    min_node_count = 1
    max_node_count = 3
  }

  node_config {
    machine_type = "e2-medium"
    disk_size_gb = 30

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }
}

# ===== Artifact Registry =====
resource "google_artifact_registry_repository" "main" {
  location      = var.region
  repository_id = "gke-practice"
  format        = "DOCKER"
}

# ===== Workload Identity Federation (GitHub Actions) =====
resource "google_iam_workload_identity_pool" "github" {
  workload_identity_pool_id = "github-pool"
  display_name              = "GitHub Actions Pool"
}

resource "google_iam_workload_identity_pool_provider" "github" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-provider"
  display_name                       = "GitHub Provider"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.actor"      = "assertion.actor"
    "attribute.repository" = "assertion.repository"
  }

  attribute_condition = "assertion.repository == \"${var.github_repo}\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account" "github_actions" {
  account_id   = "github-actions"
  display_name = "GitHub Actions SA"
}

resource "google_service_account_iam_member" "github_actions_wif" {
  service_account_id = google_service_account.github_actions.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repo}"
}

resource "google_project_iam_member" "github_actions_ar" {
  project = var.project_id
  role    = "roles/artifactregistry.writer"
  member  = "serviceAccount:${google_service_account.github_actions.email}"
}

resource "google_project_iam_member" "github_actions_gke" {
  project = var.project_id
  role    = "roles/container.developer"
  member  = "serviceAccount:${google_service_account.github_actions.email}"
}
```

- [ ] **Step 4: outputs.tf**

`terraform/outputs.tf`:
```hcl
output "cluster_endpoint" {
  value     = google_container_cluster.main.endpoint
  sensitive = true
}

output "cluster_name" {
  value = google_container_cluster.main.name
}

output "artifact_registry_url" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.main.repository_id}"
}

output "github_actions_sa_email" {
  value = google_service_account.github_actions.email
}

output "workload_identity_provider" {
  value = google_iam_workload_identity_pool_provider.github.name
}
```

- [ ] **Step 5: terraform.tfvars**

`terraform/terraform.tfvars`:
```hcl
project_id = "<YOUR_PROJECT_ID>"
region     = "asia-northeast1"
zone       = "asia-northeast1-a"
github_repo = "kyosu-1/gke-practice"
```

- [ ] **Step 6: コミット**

```bash
git add terraform/
git commit -m "feat: add Terraform config for VPC, GKE, AR, WIF"
```

---

### Task 7: Terraform — Apply

- [ ] **Step 1: terraform init**

```bash
cd terraform && terraform init
```

Expected: `Terraform has been successfully initialized!`

- [ ] **Step 2: terraform fmt + validate**

```bash
terraform fmt -check && terraform validate
```

Expected: `Success! The configuration is valid.`

- [ ] **Step 3: terraform plan**

```bash
terraform plan
```

Expected: リソース作成計画が表示される（VPC, Subnet, GKE Cluster, Node Pool, AR, IAM 等）

- [ ] **Step 4: terraform apply**

```bash
terraform apply
```

Expected: `Apply complete!` — GKE クラスタが作成される（10-15分かかる）

- [ ] **Step 5: kubectl 接続確認**

```bash
gcloud container clusters get-credentials gke-practice --zone asia-northeast1-a
kubectl get nodes
```

Expected: 1 ノードが `Ready` で表示される

---

### Task 8: Kubernetes マニフェスト — Base

**Files:**
- Create: `k8s/echo/base/deployment.yaml`
- Create: `k8s/echo/base/service.yaml`
- Create: `k8s/echo/base/kustomization.yaml`

- [ ] **Step 1: deployment.yaml**

`k8s/echo/base/deployment.yaml`:
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo
  labels:
    app: echo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: echo
  template:
    metadata:
      labels:
        app: echo
    spec:
      containers:
        - name: echo
          image: echo
          ports:
            - containerPort: 8080
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
          livenessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
          readinessProbe:
            httpGet:
              path: /health
              port: 8080
            initialDelaySeconds: 3
            periodSeconds: 5
```

- [ ] **Step 2: service.yaml**

`k8s/echo/base/service.yaml`:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: echo
spec:
  selector:
    app: echo
  ports:
    - port: 80
      targetPort: 8080
      protocol: TCP
  type: ClusterIP
```

- [ ] **Step 3: kustomization.yaml**

`k8s/echo/base/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - deployment.yaml
  - service.yaml
```

- [ ] **Step 4: kustomize build で確認**

```bash
kustomize build k8s/echo/base/
```

Expected: Deployment と Service の YAML が結合されて出力される

- [ ] **Step 5: コミット**

```bash
git add k8s/echo/base/
git commit -m "feat: add Kustomize base manifests for api (Deployment, Service)"
```

---

### Task 9: Kubernetes マニフェスト — Overlays

**Files:**
- Create: `k8s/echo/overlays/dev/kustomization.yaml`
- Create: `k8s/echo/overlays/prod/kustomization.yaml`

- [ ] **Step 1: dev overlay**

`k8s/echo/overlays/dev/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: dev

resources:
  - ../../base

images:
  - name: echo
    newName: asia-northeast1-docker.pkg.dev/<YOUR_PROJECT_ID>/gke-practice/echo
    newTag: latest

replicas:
  - name: echo
    count: 1
```

- [ ] **Step 2: prod overlay**

`k8s/echo/overlays/prod/kustomization.yaml`:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: prod

resources:
  - ../../base

images:
  - name: echo
    newName: asia-northeast1-docker.pkg.dev/<YOUR_PROJECT_ID>/gke-practice/echo
    newTag: latest

replicas:
  - name: echo
    count: 2
```

- [ ] **Step 3: overlay ビルド確認**

```bash
kustomize build k8s/echo/overlays/dev/
kustomize build k8s/echo/overlays/prod/
```

Expected: dev は namespace: dev, replicas: 1。prod は namespace: prod, replicas: 2。

- [ ] **Step 4: Namespace 作成**

```bash
kubectl create namespace dev
kubectl create namespace prod
```

- [ ] **Step 5: コミット**

```bash
git add k8s/echo/overlays/
git commit -m "feat: add Kustomize overlays for dev and prod"
```

---

### Task 10: 手動デプロイで動作確認

ArgoCD を入れる前に、マニフェストが正しいことを手動で確認する。

- [ ] **Step 1: イメージをビルドして Artifact Registry にプッシュ**

```bash
# Artifact Registry に認証
gcloud auth configure-docker asia-northeast1-docker.pkg.dev

# ビルド＆プッシュ
cd go/services/echo
docker build --platform linux/amd64 -t asia-northeast1-docker.pkg.dev/<YOUR_PROJECT_ID>/gke-practice/echo:test .
docker push asia-northeast1-docker.pkg.dev/<YOUR_PROJECT_ID>/gke-practice/echo:test
```

- [ ] **Step 2: dev overlay のタグを更新して apply**

`k8s/echo/overlays/dev/kustomization.yaml` の `newTag` を `test` に変更:

```yaml
images:
  - name: echo
    newName: asia-northeast1-docker.pkg.dev/<YOUR_PROJECT_ID>/gke-practice/echo
    newTag: test
```

```bash
kustomize build k8s/echo/overlays/dev/ | kubectl apply -f -
```

- [ ] **Step 3: Pod が起動するか確認**

```bash
kubectl get pods -n dev -w
```

Expected: Pod が `Running`, `READY 1/1` になる

- [ ] **Step 4: port-forward で動作確認**

```bash
kubectl port-forward svc/echo -n dev 8080:80
```

別ターミナルで:
```bash
curl http://localhost:8080/health
curl http://localhost:8080/api/hello
```

Expected: `{"status":"ok"}` and `{"message":"hello","hostname":"gke-practice-xxxx"}`

- [ ] **Step 5: 手動デプロイを削除（ArgoCD に任せるため）**

```bash
kustomize build k8s/echo/overlays/dev/ | kubectl delete -f -
```

---

### Task 11: ArgoCD インストール

**Files:**
- Create: `argocd/install.yaml`

- [ ] **Step 1: ArgoCD namespace 作成**

```bash
kubectl create namespace argocd
```

- [ ] **Step 2: ArgoCD インストール**

```bash
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.3/manifests/install.yaml
```

- [ ] **Step 3: ArgoCD が起動するまで待機**

```bash
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s
```

Expected: `deployment.apps/argocd-server condition met`

- [ ] **Step 4: ArgoCD CLI インストール（未インストールの場合）**

```bash
brew install argocd
```

- [ ] **Step 5: 初期パスワード取得 + ログイン**

```bash
# port-forward でアクセス
kubectl port-forward svc/argocd-server -n argocd 8443:443 &

# 初期パスワード取得
argocd admin initial-password -n argocd

# ログイン
argocd login localhost:8443 --insecure --username admin --password <初期パスワード>

# パスワード変更
argocd account update-password
```

- [ ] **Step 6: インストールメモをコミット**

`argocd/install.yaml` に使用したバージョンを記録:

```yaml
# ArgoCD v3.3.3
# Installed via: kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.3/manifests/install.yaml
# This file documents the installation method. The actual manifests are applied directly from upstream.
```

```bash
git add argocd/install.yaml
git commit -m "docs: record ArgoCD v3.3.3 installation method"
```

---

### Task 12: ArgoCD Application 設定

**Files:**
- Create: `argocd/applications/echo-dev.yaml`
- Create: `argocd/applications/echo-prod.yaml`

- [ ] **Step 1: GitHub リポジトリを ArgoCD に登録**

まず GitHub にリポジトリを作成する:

```bash
cd /Users/abe/ghq/github.com/kyosu-1/gke-practice
gh repo create kyosu-1/gke-practice --public --source=. --push
```

パブリックリポジトリなので ArgoCD からの認証は不要。

- [ ] **Step 2: dev Application 作成**

`argocd/applications/echo-dev.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: echo-dev
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/kyosu-1/gke-practice.git
    targetRevision: main
    path: k8s/echo/overlays/dev
  destination:
    server: https://kubernetes.default.svc
    namespace: dev
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 3: prod Application 作成**

`argocd/applications/echo-prod.yaml`:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: echo-prod
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/kyosu-1/gke-practice.git
    targetRevision: main
    path: k8s/echo/overlays/prod
  destination:
    server: https://kubernetes.default.svc
    namespace: prod
  syncPolicy:
    automated:
      prune: false
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
```

- [ ] **Step 4: Application を適用**

```bash
kubectl apply -f argocd/applications/echo-dev.yaml
kubectl apply -f argocd/applications/echo-prod.yaml
```

- [ ] **Step 5: ArgoCD UI で確認**

```bash
kubectl port-forward svc/argocd-server -n argocd 8443:443
```

ブラウザで `https://localhost:8443` を開き、dev と prod の Application が表示されることを確認。
この時点では k8s/echo/overlays/ のイメージタグが正しければ Synced / Healthy になる。

- [ ] **Step 6: コミット + プッシュ**

```bash
git add argocd/applications/
git commit -m "feat: add ArgoCD Applications for dev and prod"
git push
```

---

### Task 13: GitHub Actions — App CI（動的マトリクス）

**Files:**
- Create: `.github/workflows/app-ci.yaml`

- [ ] **Step 1: ワークフロー作成**

`go/services/` 配下の変更サービスを動的検知し、マトリクスで並列ビルドする。
サービス追加時にワークフロー修正は不要。

`.github/workflows/app-ci.yaml`:
```yaml
name: App CI

on:
  push:
    branches: [main]
    paths:
      - 'go/services/**'

env:
  REGION: asia-northeast1
  REGISTRY: asia-northeast1-docker.pkg.dev/<YOUR_PROJECT_ID>/gke-practice

jobs:
  detect:
    runs-on: ubuntu-latest
    permissions:
      contents: read
    outputs:
      services: ${{ steps.changes.outputs.services }}
    steps:
      - name: Checkout
        uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6
        with:
          fetch-depth: 2

      - name: Detect changed services
        id: changes
        run: |
          SERVICES=$(git diff --name-only HEAD~1 HEAD \
            | grep '^go/services/' | cut -d/ -f3 | sort -u \
            | jq -R -s -c 'split("\n") | map(select(. != ""))')
          echo "services=$SERVICES" >> "$GITHUB_OUTPUT"
          echo "Changed services: $SERVICES"

  test:
    needs: detect
    if: needs.detect.outputs.services != '[]'
    runs-on: ubuntu-latest
    permissions:
      contents: read
    strategy:
      matrix:
        service: ${{ fromJson(needs.detect.outputs.services) }}
    steps:
      - name: Checkout
        uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6

      - name: Setup Go
        uses: actions/setup-go@4a3601121dd01d1626a1e23e37211e3254c1c06c # v6
        with:
          go-version: '1.26'

      - name: Test
        working-directory: go/services/${{ matrix.service }}
        run: go test -v ./...

  build-and-push:
    needs: [detect, test]
    if: needs.detect.outputs.services != '[]'
    runs-on: ubuntu-latest
    permissions:
      contents: write
      id-token: write
    strategy:
      matrix:
        service: ${{ fromJson(needs.detect.outputs.services) }}
    steps:
      - name: Checkout
        uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6

      - name: Authenticate to GCP
        uses: google-github-actions/auth@7c6bc770dae815cd3e89ee6cdf493a5fab2cc093 # v3
        with:
          workload_identity_provider: 'projects/<YOUR_PROJECT_NUMBER>/locations/global/workloadIdentityPools/github-pool/providers/github-provider'
          service_account: 'github-actions@<YOUR_PROJECT_ID>.iam.gserviceaccount.com'

      - name: Configure Docker
        run: gcloud auth configure-docker ${REGION}-docker.pkg.dev --quiet

      - name: Build and Push
        working-directory: go/services/${{ matrix.service }}
        run: |
          IMAGE_TAG=${GITHUB_SHA::7}
          docker build --platform linux/amd64 -t ${REGISTRY}/${{ matrix.service }}:${IMAGE_TAG} .
          docker push ${REGISTRY}/${{ matrix.service }}:${IMAGE_TAG}

      - name: Update dev image tag
        run: |
          IMAGE_TAG=${GITHUB_SHA::7}
          cd k8s/${{ matrix.service }}/overlays/dev
          kustomize edit set image ${{ matrix.service }}=${REGISTRY}/${{ matrix.service }}:${IMAGE_TAG}
          cd ../../../..
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git add k8s/${{ matrix.service }}/overlays/dev/kustomization.yaml
          git diff --cached --quiet || git commit -m "ci: update ${{ matrix.service }} dev image tag to ${IMAGE_TAG}" && git push
```

- [ ] **Step 2: コミット + プッシュ**

```bash
mkdir -p .github/workflows
git add .github/workflows/app-ci.yaml
git commit -m "feat: add GitHub Actions CI with dynamic service detection"
git push
```

- [ ] **Step 3: GitHub Actions の実行確認**

```bash
gh run list --workflow=app-ci.yaml
```

`go/services/echo/` を変更してプッシュし、ワークフローが起動することを確認。

---

### Task 14: GitHub Actions — Terraform CI

**Files:**
- Create: `.github/workflows/terraform.yaml`

- [ ] **Step 1: ワークフロー作成**

`.github/workflows/terraform.yaml`:
```yaml
name: Terraform

on:
  push:
    branches: [main]
    paths:
      - 'terraform/**'
  pull_request:
    paths:
      - 'terraform/**'

env:
  TF_VERSION: '1.14.8'

jobs:
  plan:
    runs-on: ubuntu-latest
    if: github.event_name == 'pull_request'
    permissions:
      contents: read
      id-token: write
      pull-requests: write
    steps:
      - name: Checkout
        uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6

      - name: Authenticate to GCP
        uses: google-github-actions/auth@7c6bc770dae815cd3e89ee6cdf493a5fab2cc093 # v3
        with:
          workload_identity_provider: 'projects/<YOUR_PROJECT_NUMBER>/locations/global/workloadIdentityPools/github-pool/providers/github-provider'
          service_account: 'github-actions@<YOUR_PROJECT_ID>.iam.gserviceaccount.com'

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@b9cd54a3c349d3f38e8881555d616ced269862dd # v3
        with:
          terraform_version: ${{ env.TF_VERSION }}

      - name: Terraform Init
        working-directory: terraform
        run: terraform init

      - name: Terraform Format Check
        working-directory: terraform
        run: terraform fmt -check

      - name: Terraform Plan
        working-directory: terraform
        run: terraform plan -no-color
        id: plan

      - name: Comment PR
        uses: actions/github-script@f28e40c7f34bde8b3046d885e986cb6290c5673b # v7
        env:
          PLAN_OUTPUT: ${{ steps.plan.outputs.stdout }}
        with:
          script: |
            const output = `#### Terraform Plan
            \`\`\`
            ${process.env.PLAN_OUTPUT}
            \`\`\`
            `;
            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: output
            });

  apply:
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    environment: production
    permissions:
      contents: read
      id-token: write
    steps:
      - name: Checkout
        uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6

      - name: Authenticate to GCP
        uses: google-github-actions/auth@7c6bc770dae815cd3e89ee6cdf493a5fab2cc093 # v3
        with:
          workload_identity_provider: 'projects/<YOUR_PROJECT_NUMBER>/locations/global/workloadIdentityPools/github-pool/providers/github-provider'
          service_account: 'github-actions@<YOUR_PROJECT_ID>.iam.gserviceaccount.com'

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@b9cd54a3c349d3f38e8881555d616ced269862dd # v3
        with:
          terraform_version: ${{ env.TF_VERSION }}

      - name: Terraform Init
        working-directory: terraform
        run: terraform init

      - name: Terraform Apply
        working-directory: terraform
        run: terraform apply -auto-approve
```

- [ ] **Step 2: コミット + プッシュ**

```bash
git add .github/workflows/terraform.yaml
git commit -m "feat: add GitHub Actions CI for Terraform plan/apply"
git push
```

---

### Task 15: Dependabot 設定（GitHub Actions 自動更新）

コミットハッシュで固定した Actions を Dependabot で自動更新する。

**Files:**
- Create: `.github/dependabot.yml`

- [ ] **Step 1: Dependabot 設定ファイル作成**

`.github/dependabot.yml`:
```yaml
version: 2
updates:
  - package-ecosystem: "github-actions"
    directory: "/"
    schedule:
      interval: "weekly"
```

- [ ] **Step 2: コミット + プッシュ**

```bash
git add .github/dependabot.yml
git commit -m "ci: add Dependabot config for GitHub Actions version updates"
git push
```

---

### Task 16: E2E 動作確認

全体のフローが正しく動くことを確認する。

- [ ] **Step 1: go/services/echo/ に小さな変更を加えてプッシュ**

`go/services/echo/main.go` の hello レスポンスに `"version": "v1"` を追加:

```go
func helloHandler(w http.ResponseWriter, r *http.Request) {
	hostname, _ := os.Hostname()
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]string{
		"message":  "hello",
		"hostname": hostname,
		"version":  "v1",
	})
}
```

テストも更新:

```go
func TestHelloHandler(t *testing.T) {
	// ... existing code ...
	if resp["version"] != "v1" {
		t.Errorf("expected version v1, got %s", resp["version"])
	}
}
```

```bash
cd go/services/echo && go test -v ./...
git add go/services/echo/
git commit -m "feat: add version field to hello endpoint"
git push
```

- [ ] **Step 2: GitHub Actions の実行を確認**

```bash
gh run watch
```

Expected: テスト → ビルド → プッシュ → タグ更新 が成功

- [ ] **Step 3: ArgoCD の同期を確認**

```bash
argocd app get echo-dev
```

Expected: `Status: Synced`, `Health: Healthy`

- [ ] **Step 4: Pod で新バージョンが動いていることを確認**

```bash
kubectl port-forward svc/echo -n dev 8080:80
curl http://localhost:8080/api/hello
```

Expected: `{"message":"hello","hostname":"...","version":"v1"}`

- [ ] **Step 5: 確認完了コミット（タグ）**

```bash
git tag v0.1.0
git push origin v0.1.0
```

---

## Summary

| Task | 内容 | 成果物 |
|---|---|---|
| 1 | リポジトリ初期化 | .gitignore |
| 2 | Go テスト作成 | go/services/echo/main_test.go |
| 3 | Go 実装 | go/services/echo/main.go |
| 4 | Dockerfile | go/services/echo/Dockerfile |
| 5 | GCS バケット作成 | tfstate バケット |
| 6 | Terraform 定義 | terraform/*.tf |
| 7 | Terraform apply | GKE クラスタ稼働 |
| 8 | K8s base マニフェスト | k8s/echo/base/ |
| 9 | K8s overlays | k8s/echo/overlays/dev, prod |
| 10 | 手動デプロイ確認 | Pod 動作確認済 |
| 11 | ArgoCD インストール | argocd namespace |
| 12 | ArgoCD Application | argocd/applications/ |
| 13 | App CI workflow (動的マトリクス) | .github/workflows/app-ci.yaml |
| 14 | Terraform CI workflow | .github/workflows/terraform.yaml |
| 15 | Dependabot 設定 | .github/dependabot.yml |
| 16 | E2E 動作確認 | 全フロー疎通済、v0.1.0 タグ |
