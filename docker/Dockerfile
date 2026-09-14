# syntax=docker/dockerfile:1

# ---- 依存関係の解決（vendor/ を生成） ----
FROM composer:2 AS vendor
WORKDIR /app
COPY app/composer.json app/composer.lock ./
# 実行環境（php:8.3-apache）に合わせて lock どおりにインストールする。
# ビルド用イメージの PHP 拡張の有無に左右されないよう platform 要件は無視する
RUN composer install --no-dev --no-interaction --no-progress --optimize-autoloader --ignore-platform-reqs

# ---- 実行イメージ（Apache + PHP 8.3。現行 EC2 の Apache/PHP 構成に相当） ----
# Cloud Run にデプロイするのはこのステージ。最終ステージは dev なので、ビルド時は --target runtime を指定する
FROM php:8.3-apache AS runtime

# Cloud Run は PORT 環境変数で待ち受けポートを指定する。既定は 8080
ENV PORT=8080 \
    DATA_DIR=/mnt/data \
    WRITE_MODE=lock

# Apache の待ち受けポートと VirtualHost を PORT 環境変数で決める設定に差し替える。
# access/error ログは stdout/stderr へ（Cloud Logging に自動収集される）
COPY docker/apache/ports.conf /etc/apache2/ports.conf
COPY docker/apache/000-default.conf /etc/apache2/sites-available/000-default.conf

# アプリ本体と依存関係
COPY app/ /var/www/html/
COPY --from=vendor /app/vendor /var/www/html/vendor

# ローカル（docker compose）での DATA_DIR。Cloud Run ではここに Cloud Storage ボリュームをマウントする
RUN mkdir -p /mnt/data && chown www-data:www-data /mnt/data

WORKDIR /var/www/html
EXPOSE 8080

# ---- 開発用（Dev Container）。実行イメージ runtime には含めない ----
# runtime と同じ Apache/PHP のまま、git / composer など開発に必要なツールだけを足す。
# AWS CLI や Terraform は .devcontainer/devcontainer.json の features で載せる
FROM runtime AS dev
RUN apt-get update \
    && apt-get install -y --no-install-recommends git unzip less \
    && rm -rf /var/lib/apt/lists/*
COPY --from=composer:2 /usr/bin/composer /usr/local/bin/composer
