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

マルチステージビルドでビルド環境と実行環境を分離し、Distroless イメージで最小限の実行環境を実現する。本セクションでは、ビルドキャッシュの仕組み、Go 固有の最適化、Distroless の内部構造、セキュリティ、クロスプラットフォームビルド、代替イメージとの比較まで包括的にカバーする。

---

### 4.1 マルチステージビルドの仕組み

#### 基本構造

マルチステージビルドでは、1 つの Dockerfile 内に複数の `FROM` 命令を記述する。各 `FROM` が新しいビルドステージを開始し、`AS` キーワードで名前を付けられる。最終ステージのみが最終イメージとなり、中間ステージは破棄される。

```dockerfile
# syntax=docker/dockerfile:1

# ---- Stage 1: 依存関係の解決 ----
FROM golang:1.24 AS deps
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download

# ---- Stage 2: ビルド ----
FROM deps AS builder
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /server .

# ---- Stage 3: 実行環境 ----
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /server /server
ENTRYPOINT ["/server"]
```

#### `COPY --from` の詳細

`COPY --from` はファイルのコピー元を指定するディレクティブである。以下の 3 パターンで使用できる。

```dockerfile
# パターン1: 名前付きステージからコピー
COPY --from=builder /app/server /server

# パターン2: ステージ番号（0始まり）でコピー
COPY --from=0 /app/server /server

# パターン3: 外部イメージから直接コピー（ビルドステージ外）
COPY --from=alpine:3.20 /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
```

パターン 3 は特に便利で、CA 証明書やタイムゾーンデータだけを別イメージから取得したい場合に使える。

#### 名前付きステージの活用

名前付きステージは `--target` フラグと組み合わせることで、特定のステージだけをビルドできる。これは開発時とプロダクション時で異なるイメージを使い分ける場合に有効。

```bash
# 開発用ステージだけをビルド
docker build --target=dev -t myapp:dev .

# テスト用ステージだけをビルド（CI で利用）
docker build --target=test -t myapp:test .
```

```dockerfile
FROM golang:1.24 AS base
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download

FROM base AS dev
# ホットリロードツール付き開発イメージ
RUN go install github.com/air-verse/air@latest
CMD ["air"]

FROM base AS test
COPY . .
RUN go test ./...

FROM base AS builder
COPY . .
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /server .

FROM gcr.io/distroless/static-debian12:nonroot AS production
COPY --from=builder /server /server
ENTRYPOINT ["/server"]
```

#### ステージ間でのビルド引数 (ARG)

`ARG` はステージごとにスコープが限定される。複数ステージで同じ引数を使いたい場合は、`FROM` の前にグローバル ARG を宣言し、各ステージ内で再宣言する。

```dockerfile
# グローバル ARG（全ステージから参照可能だが再宣言が必要）
ARG GO_VERSION=1.24
ARG APP_VERSION=unknown

FROM golang:${GO_VERSION} AS builder
# ステージ内で再宣言しないと使えない
ARG APP_VERSION
WORKDIR /app
COPY . .
RUN CGO_ENABLED=0 go build -ldflags="-s -w -X main.version=${APP_VERSION}" -o /server .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /server /server
ENTRYPOINT ["/server"]
```

```bash
# ビルド時に引数を渡す
docker build --build-arg GO_VERSION=1.24 --build-arg APP_VERSION=v1.2.3 .
```

#### Docker ビルドキャッシュの仕組み

Docker（BuildKit）はレイヤーキャッシュを利用してビルドを高速化する。各命令（`RUN`, `COPY`, `ADD` など）が個別のレイヤーを生成し、入力が変わらない限りキャッシュが再利用される。

**キャッシュ無効化のルール:**

1. `COPY` / `ADD`: コピー対象のファイル内容のハッシュが変われば無効化
2. `RUN`: コマンド文字列が変われば無効化（`--mount=type=cache` を除く）
3. あるレイヤーのキャッシュが無効化されると、**それ以降の全レイヤーも再ビルド**される

**BuildKit の並列ビルド:** BuildKit は依存関係のないステージを自動的に並列実行する。最終ステージが参照しないステージはスキップされるため、不要なビルドコストが発生しない。

#### キャッシュマウント (`--mount=type=cache`)

`RUN --mount=type=cache` はビルド間で永続するキャッシュディレクトリをマウントする機能である。キャッシュ内容は最終イメージに含まれないため、イメージサイズに影響しない。

```dockerfile
# syntax=docker/dockerfile:1
FROM golang:1.24 AS builder
WORKDIR /app
COPY go.mod go.sum ./

# Go モジュールキャッシュとビルドキャッシュを永続マウント
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go mod download

COPY . .
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 go build -ldflags="-s -w" -o /server .
```

**効果:** キャッシュマウントにより、小さなコード変更だけのリビルドが約 11 秒から 2 秒未満に短縮された事例がある。

---

### 4.2 Go 固有の最適化

#### `CGO_ENABLED=0` の意味

Go はデフォルトで C ライブラリ（libc）に動的リンクする場合がある（例: `net` パッケージの DNS 解決、`os/user` パッケージ）。`CGO_ENABLED=0` を設定すると、C コードへの依存を完全に排除し、純粋な Go 実装にフォールバックする。

```bash
# CGO 有効（デフォルト）: 動的リンクされたバイナリ
$ go build -o server .
$ ldd server
    linux-vdso.so.1
    libc.so.6 => /lib/x86_64-linux-gnu/libc.so.6

# CGO 無効: 完全な静的バイナリ
$ CGO_ENABLED=0 go build -o server .
$ ldd server
    not a dynamic executable
```

**なぜ重要か:** `distroless/static` や `scratch` には共有ライブラリが含まれないため、動的リンクされたバイナリは実行時にクラッシュする。`CGO_ENABLED=0` は Distroless + Go の組み合わせにおいて必須の設定。

#### 静的リンク vs 動的リンク

| 項目 | 静的リンク (`CGO_ENABLED=0`) | 動的リンク（デフォルト） |
|---|---|---|
| バイナリサイズ | やや大きい | 小さい |
| 依存関係 | なし（自己完結） | libc 等が必要 |
| 互換性 | どの Linux でも動作 | glibc バージョンに依存 |
| 適合イメージ | scratch, distroless/static | distroless/base, alpine |
| DNS 解決 | 純 Go リゾルバ | glibc の getaddrinfo |

CGO が必要な場合（SQLite バインディングなど）は、`-linkmode external -extldflags '-static'` で静的リンクを強制するか、`distroless/base`（glibc 含む）を使用する。

#### `-ldflags` によるバイナリ最適化

```bash
CGO_ENABLED=0 go build -ldflags="-s -w" -o server .
```

| フラグ | 効果 | サイズ削減 |
|---|---|---|
| `-s` | シンボルテーブルとデバッグ情報を除去 | 約 25-30% |
| `-w` | DWARF シンボルテーブルを除去（Go 1.22 以降は `-s` に含まれる） | `-s` と併用で追加効果なし |
| `-X main.version=...` | ビルド時にバージョン情報を埋め込み | -- |

```dockerfile
# バージョン情報を埋め込みつつデバッグ情報を除去
RUN CGO_ENABLED=0 go build \
    -ldflags="-s -w -X main.version=${APP_VERSION} -X main.buildTime=$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    -o /server .
```

#### `go mod download` レイヤーキャッシュパターン

Go の依存関係ダウンロードを独立したレイヤーとして分離することで、ソースコード変更時に依存関係の再ダウンロードを回避する。

```dockerfile
FROM golang:1.24 AS builder
WORKDIR /app

# Step 1: 依存関係定義ファイルだけを先にコピー
COPY go.mod go.sum ./

# Step 2: 依存関係をダウンロード（go.mod/go.sum が変わらない限りキャッシュ有効）
RUN go mod download

# Step 3: ソースコードをコピー（ここからキャッシュが無効化される可能性あり）
COPY . .

# Step 4: ビルド
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /server .
```

**なぜ効くか:** `go.mod` と `go.sum` はソースコードほど頻繁に変わらない。先にコピーしてダウンロードすることで、ソースコード変更時でも Step 2 のキャッシュが再利用される。

---

### 4.3 Distroless 詳細解説

#### イメージの内部構成

Distroless イメージは Google が提供する「OS なし」コンテナイメージである。パッケージマネージャ、シェル、標準的な Unix ユーティリティを一切含まない。

**`distroless/static` に含まれるもの:**

| ファイル/ディレクトリ | 目的 |
|---|---|
| `/etc/ssl/certs/ca-certificates.crt` | TLS 通信用 CA 証明書バンドル |
| `/usr/share/zoneinfo/` | タイムゾーンデータ（`time.LoadLocation()` 用） |
| `/etc/passwd` | root と nonroot ユーザーのエントリ |
| `/etc/group` | root と nonroot グループのエントリ |
| `/tmp` | 一時ファイル用ディレクトリ |
| `/etc/nsswitch.conf` | ネームサービスの解決順序設定 |

**含まれないもの:** `/bin/sh`, `bash`, `apt`, `apk`, `ls`, `cat`, `curl`, `wget` 等すべてのシェル・ユーティリティ

#### イメージバリアント

Distroless は用途に応じて段階的なバリアントを提供する。上位バリアントは下位の内容をすべて含む。

```
distroless/static (最小: ca-certs, tzdata, passwd)
    └── distroless/base (+ glibc, libssl, openssl)
        └── distroless/cc (+ libgcc, libstdc++)
            └── distroless/python3, distroless/java など (+ ランタイム)
```

| バリアント | 追加内容 | 用途 | 圧縮サイズ |
|---|---|---|---|
| `static-debian12` | なし（基本セット） | Go, Rust 等の静的バイナリ | ~2 MiB |
| `base-debian12` | glibc, libssl | C ライブラリ依存アプリ | ~20 MiB |
| `cc-debian12` | libgcc, libstdc++ | C++ ランタイム依存アプリ | ~25 MiB |
| `java21-debian12` | OpenJDK 21 | Java アプリ | ~100 MiB |
| `python3-debian12` | Python 3 ランタイム | Python アプリ | ~50 MiB |

#### `:nonroot` タグ

`:nonroot` タグのイメージは、デフォルトのユーザーが UID 65534（`nobody`）に設定されている。Kubernetes 環境では `runAsNonRoot: true` と組み合わせて使用する。

```dockerfile
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /server /server
# USER 命令は不要（イメージ自体が nonroot ユーザーで設定済み）
ENTRYPOINT ["/server"]
```

`/etc/passwd` の内容:
```
root:x:0:0:root:/root:/sbin/nologin
nobody:x:65534:65534:nobody:/nonexistent:/sbin/nologin
```

#### `:debug` タグ（トラブルシューティング用）

本番環境では使わないが、開発・デバッグ時に便利な debug タグが用意されている。BusyBox シェルが `/busybox/sh` に配置される。

```bash
# debug イメージでコンテナを起動
docker run -it --name debug-test gcr.io/distroless/static-debian12:debug /busybox/sh

# 実行中コンテナに exec でシェルを取得
docker exec -it debug-test /busybox/sh
```

`:nonroot` と組み合わせる場合は `:debug-nonroot` タグを使用する。

```dockerfile
# デバッグ用 Dockerfile
FROM gcr.io/distroless/static-debian12:debug-nonroot
COPY --from=builder /server /server
ENTRYPOINT ["/server"]
```

**代替デバッグ手法:**
- `kubectl debug` を使ってエフェメラルコンテナを追加する
- サイドカーコンテナ（`--pid container:`, `--network container:`）でプロセス/ネットワーク名前空間を共有する

---

### 4.4 イメージサイズ比較

Go アプリケーション（Hello World 程度）をマルチステージビルドした場合の最終イメージサイズ比較:

| ベースイメージ | 最終イメージサイズ | 備考 |
|---|---|---|
| `golang:1.24` | ~850 MB | ビルドツール全部入り（本番非推奨） |
| `golang:1.24-alpine` | ~250 MB | Alpine ベースのビルドイメージ |
| `ubuntu:24.04` + バイナリ | ~78 MB | 汎用 OS イメージ |
| `alpine:3.20` + バイナリ | ~12 MB | 軽量 Linux + バイナリ |
| `gcr.io/distroless/base-debian12` | ~25 MB | glibc 含むベースイメージ |
| `gcr.io/distroless/static-debian12` | ~5 MB | 静的バイナリ向け最小イメージ |
| `cgr.dev/chainguard/static` | ~5 MB | Chainguard の同等イメージ |
| `scratch` + バイナリ | ~3 MB | 完全空イメージ + バイナリのみ |

**注:** 上記サイズはバイナリサイズを含む圧縮後の概算値。実際のバイナリサイズはアプリケーション規模に依存する。

`golang:1.24`（~850 MB）から `distroless/static`（~5 MB）への切り替えで **約 99% のサイズ削減** が実現できる。

---

### 4.5 セキュリティ

#### シェルが存在しないことの意義（RCE 軽減）

Distroless イメージにはシェルが含まれないため、攻撃者がリモートコード実行（RCE）脆弱性を悪用してもシェルアクセスを取得できない。

**軽減される攻撃パターン:**
- `; rm -rf /` のようなコマンドインジェクション
- リバースシェルの起動（`/bin/sh -c` が存在しない）
- パッケージマネージャを利用したマルウェアのインストール

**限界:** シェルがなくても完全に安全ではない点に注意。
- Go バイナリ自体の脆弱性を悪用した任意コード実行は防げない
- `execve()` システムコールによる直接実行は可能
- ファイルレスマルウェアやメモリベースの攻撃は影響しうる

シェル除去は「多層防御（Defense in Depth）」の一層として位置づけるべきである。

#### SBOM（Software Bill of Materials）と脆弱性スキャン

コンテナイメージに含まれるすべてのソフトウェアコンポーネントを可視化し、既知の脆弱性を検出する仕組み。

```bash
# Syft で SBOM を生成
syft gcr.io/distroless/static-debian12:nonroot -o spdx-json > sbom.json

# Trivy でイメージの脆弱性スキャン
trivy image gcr.io/distroless/static-debian12:nonroot

# Grype で SBOM ベースの脆弱性スキャン
grype sbom:sbom.json
```

Distroless イメージはパッケージが極めて少ないため、検出される CVE の数も少ない傾向がある。

#### Cosign によるイメージ署名

[Cosign](https://github.com/sigstore/cosign) はコンテナイメージに暗号署名を付与し、改ざんを検知するツール。Sigstore プロジェクトの一部。

```bash
# キーペアの生成
cosign generate-key-pair

# イメージに署名
cosign sign --key cosign.key myregistry/myapp:v1.0.0

# 署名の検証
cosign verify --key cosign.pub myregistry/myapp:v1.0.0

# キーレス署名（Sigstore の Fulcio / Rekor を利用）
cosign sign myregistry/myapp:v1.0.0
```

CI/CD パイプラインで署名を自動化し、デプロイ前に署名検証を行う運用が推奨される。Kubernetes では [Kyverno](https://kyverno.io/) や [OPA Gatekeeper](https://open-policy-agent.github.io/gatekeeper/) で署名検証ポリシーを適用できる。

---

### 4.6 クロスプラットフォームビルド

#### `--platform` フラグ

Apple Silicon Mac（ARM64）で開発し、GKE（AMD64）にデプロイする場合、ターゲットプラットフォームを明示的に指定する必要がある。

```bash
# linux/amd64 向けにビルド（ARM Mac 上で実行）
docker build --platform linux/amd64 -t myapp:latest .
```

Dockerfile 内でも指定可能:

```dockerfile
FROM --platform=linux/amd64 golang:1.24 AS builder
# ...
FROM --platform=linux/amd64 gcr.io/distroless/static-debian12:nonroot
# ...
```

#### Docker Buildx によるマルチアーキテクチャビルド

`docker buildx` は BuildKit ベースの拡張ビルドツール。複数アーキテクチャ向けのイメージを一度にビルドできる。

```bash
# Buildx ビルダーの作成と使用
docker buildx create --name mybuilder --use
docker buildx inspect --bootstrap

# マルチアーキテクチャビルド & レジストリへの push
docker buildx build \
    --platform linux/amd64,linux/arm64 \
    --push \
    -t myregistry/myapp:v1.0.0 .
```

**内部動作:** BuildKit は QEMU エミュレーションを使用して異なるアーキテクチャのバイナリをビルドする。Docker Desktop には QEMU が同梱されているため、追加設定は不要。

**パフォーマンス上の注意:** QEMU によるエミュレーションビルドはネイティブビルドより大幅に遅い。Go の場合はクロスコンパイル（`GOOS`/`GOARCH` の指定）のほうが高速:

```dockerfile
# QEMU エミュレーションを回避するクロスコンパイルパターン
FROM --platform=$BUILDPLATFORM golang:1.24 AS builder
ARG TARGETPLATFORM
ARG TARGETOS
ARG TARGETARCH
WORKDIR /app
COPY . .
RUN CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -ldflags="-s -w" -o /server .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /server /server
ENTRYPOINT ["/server"]
```

`$BUILDPLATFORM` でビルドホストのネイティブプラットフォームを使い、Go のクロスコンパイル機能で対象アーキテクチャ向けにビルドする。QEMU が不要になるため、ビルド速度が劇的に向上する。

---

### 4.7 Dockerfile ベストプラクティス

#### レイヤー順序とキャッシュ効率

変更頻度の低い命令を先に、変更頻度の高い命令を後に配置する。

```dockerfile
# 推奨順序
FROM golang:1.24 AS builder
WORKDIR /app

# 1. 変更頻度: 極めて低い -> 先に配置
COPY go.mod go.sum ./
RUN go mod download

# 2. 変更頻度: 高い -> 後に配置
COPY . .
RUN CGO_ENABLED=0 go build -ldflags="-s -w" -o /server .
```

#### `.dockerignore` の活用

ビルドコンテキストから不要なファイルを除外し、ビルド速度向上とイメージへの不要ファイル混入を防止する。

```text
# .dockerignore
.git
.github
.gitignore
*.md
LICENSE
docs/
vendor/
bin/
tmp/
.env
.env.*
docker-compose*.yml
Makefile
```

#### HEALTHCHECK 命令

Docker Swarm や単体 Docker 環境でコンテナのヘルスチェックを行う命令。Kubernetes 環境では `livenessProbe` / `readinessProbe` を使うため不要だが、Docker 単体テスト時に有用。

```dockerfile
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /server /server

# 30秒ごとにヘルスチェック（Distroless にはcurlがないためバイナリ内にヘルスチェック機能を組み込む）
# 注意: Distroless ではシェルが使えないため exec 形式で指定
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
    CMD ["/server", "-health-check"]

ENTRYPOINT ["/server"]
```

**注意:** Distroless にはシェルも curl もないため、ヘルスチェック用のサブコマンドをアプリケーション自体に組み込む必要がある。

#### 非 root 実行の徹底

```dockerfile
# 方法1: nonroot タグを使用（推奨）
FROM gcr.io/distroless/static-debian12:nonroot
# UID 65534 で自動的に実行される

# 方法2: USER 命令で明示的に指定
FROM gcr.io/distroless/static-debian12
USER 65534:65534
```

Kubernetes マニフェストでも `securityContext` で強制する:

```yaml
securityContext:
  runAsNonRoot: true
  runAsUser: 65534
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  capabilities:
    drop:
      - ALL
```

#### 本プロジェクト向け推奨 Dockerfile（完全版）

```dockerfile
# syntax=docker/dockerfile:1

# ===== グローバルARG =====
ARG GO_VERSION=1.24
ARG APP_VERSION=dev

# ===== Stage 1: 依存関係 =====
FROM --platform=$BUILDPLATFORM golang:${GO_VERSION} AS deps
WORKDIR /app
COPY go.mod go.sum ./
RUN --mount=type=cache,target=/go/pkg/mod \
    go mod download

# ===== Stage 2: ビルド =====
FROM deps AS builder
ARG TARGETOS
ARG TARGETARCH
ARG APP_VERSION
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    CGO_ENABLED=0 GOOS=${TARGETOS} GOARCH=${TARGETARCH} \
    go build -ldflags="-s -w -X main.version=${APP_VERSION}" \
    -o /server .

# ===== Stage 3: テスト（CI 用） =====
FROM deps AS test
COPY . .
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    go test -race -cover ./...

# ===== Stage 4: 本番 =====
FROM gcr.io/distroless/static-debian12:nonroot AS production
COPY --from=builder /server /server
EXPOSE 8080
ENTRYPOINT ["/server"]
```

```bash
# ビルド例
docker buildx build \
    --platform linux/amd64 \
    --build-arg APP_VERSION=$(git describe --tags --always) \
    --target production \
    -t myapp:latest .
```

---

### 4.8 代替最小イメージとの比較

#### scratch

Docker が提供する完全に空のベースイメージ。ファイルシステムの内容はゼロバイト。

```dockerfile
FROM scratch
COPY --from=builder /server /server
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /usr/share/zoneinfo /usr/share/zoneinfo
ENTRYPOINT ["/server"]
```

**メリット:**
- 最小サイズ（バイナリのみ）
- 攻撃対象面が最も小さい

**デメリット:**
- CA 証明書、タイムゾーンデータ、`/etc/passwd` を手動でコピーする必要あり
- debug タグがない（デバッグ不可）
- ユーザーエントリがないため、数値 UID で `USER` を指定する必要あり

#### Alpine

musl libc ベースの軽量 Linux ディストリビューション（~5 MB）。

```dockerfile
FROM alpine:3.20
RUN apk add --no-cache ca-certificates tzdata
COPY --from=builder /server /server
USER 65534:65534
ENTRYPOINT ["/server"]
```

**メリット:**
- シェルとパッケージマネージャが利用可能（デバッグ容易）
- apk で追加パッケージをインストール可能
- CVE が少ない傾向

**デメリット:**
- musl libc と glibc の互換性問題が発生する場合がある
- シェルの存在はセキュリティリスク
- Distroless より大きい（~12 MB vs ~5 MB）

#### Chainguard Images

[Chainguard](https://www.chainguard.dev/) が提供する Wolfi ベースのセキュアなコンテナイメージ。Distroless の精神的後継とも言える。

```dockerfile
FROM cgr.dev/chainguard/static:latest
COPY --from=builder /server /server
ENTRYPOINT ["/server"]
```

**メリット:**
- apko ベースで拡張しやすい（Bazel 不要）
- Wolfi OS による日次セキュリティアップデート
- ゼロ CVE を目指した設計
- SBOM が組み込み済み
- Cosign 署名済み

**デメリット:**
- 無料版は `:latest` タグのみ（固定バージョンは有料）
- Google Distroless ほどの実績・ドキュメントがまだ少ない

#### 比較まとめ

| 特性 | scratch | distroless/static | Alpine | Chainguard/static |
|---|---|---|---|---|
| サイズ | ~0 MB + binary | ~2 MB + binary | ~5 MB + binary | ~2 MB + binary |
| シェル | なし | なし | あり | なし |
| パッケージマネージャ | なし | なし | apk | なし（apko で拡張） |
| CA 証明書 | 手動コピー | 含む | apk で追加 | 含む |
| tzdata | 手動コピー | 含む | apk で追加 | 含む |
| /etc/passwd | 手動作成 | 含む | 含む | 含む |
| debug タグ | なし | あり | 不要（シェルあり） | あり |
| CVE | N/A | 少ない | 少ない | 極めて少ない |
| SBOM | なし | なし | なし | 組み込み済み |
| 署名 | なし | なし | なし | Cosign 署名済み |
| 推奨ケース | 最小化最優先 | Go 本番運用（推奨） | デバッグ必要時 | セキュリティ最優先 |

**本プロジェクトでの選択:** `gcr.io/distroless/static-debian12:nonroot` を採用。Go の静的バイナリとの相性、CA 証明書/tzdata の自動包含、nonroot ユーザー設定、debug タグの存在など、バランスが最も良い。

---

### 参考URL

- [Docker マルチステージビルド公式ドキュメント](https://docs.docker.com/build/building/multi-stage/)
- [Docker ビルドキャッシュ最適化](https://docs.docker.com/build/cache/optimize/)
- [Docker ベストプラクティス](https://docs.docker.com/build/building/best-practices/)
- [Docker マルチプラットフォームビルド](https://docs.docker.com/build/building/multi-platform/)
- [Distroless コンテナイメージ (GitHub)](https://github.com/GoogleContainerTools/distroless)
- [Distroless の内部構造の詳細解説](https://labs.iximiuz.com/tutorials/gcr-distroless-container-images)
- [Alpine vs Distroless vs Scratch 比較](https://medium.com/google-cloud/alpine-distroless-or-scratch-caac35250e0b)
- [Chainguard Images 公式ドキュメント](https://edu.chainguard.dev/chainguard/chainguard-images/overview/)
- [Cosign と Distroless によるコンテナセキュリティ (CNCF)](https://www.cncf.io/blog/2021/09/14/how-to-secure-containers-with-cosign-and-distroless-images/)
- [Docker イメージセキュリティベストプラクティス](https://bell-sw.com/blog/docker-image-security-best-practices-for-production/)
- [Go Docker イメージサイズ比較](https://laurent-bel.medium.com/running-go-on-docker-comparing-debian-vs-alpine-vs-distroless-vs-busybox-vs-scratch-18b8c835d9b8)
- [Go Docker ビルド高速化 (20x)](https://dev.to/jacktt/20x-faster-golang-docker-builds-289n)
- [Advanced multi-stage build patterns](https://medium.com/@tonistiigi/advanced-multi-stage-build-patterns-6f741b852fae)
- [Distroless セキュリティの限界](https://www.anantacloud.com/post/beyond-distroless-the-hidden-risks-in-secure-minimal-containers)
- [Minimal container images の未来 (Chainguard)](https://www.chainguard.dev/unchained/minimal-container-images-towards-a-more-secure-future)
- [コンテナイメージ改善の全体像](https://iximiuz.com/en/posts/containers-making-images-better/)

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
