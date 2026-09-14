<?php

declare(strict_types=1);

namespace App;

use Aws\S3\S3Client;

/**
 * JSON を AWS S3 へアップロードする。
 *
 * 認証情報はこのクラスでは扱わず、AWS SDK の既定プロバイダチェーン
 * （環境変数 → 共有設定ファイル → ... ）に委ねる。Cloud Run では #6 で
 * Workload Identity Federation のプロバイダを $credentials として注入する。
 */
final class S3Uploader
{
    private readonly S3Client $client;

    /**
     * @param callable|null $credentials AWS SDK のクレデンシャルプロバイダ。null なら既定チェーン
     */
    public function __construct(
        private readonly Config $config,
        ?callable $credentials = null,
        ?S3Client $client = null,
    ) {
        $args = [
            'version' => 'latest',
            'region' => $this->config->awsRegion,
        ];

        // MinIO など S3 互換エンドポイントを使う場合
        if ($this->config->s3Endpoint !== null) {
            $args['endpoint'] = $this->config->s3Endpoint;
            $args['use_path_style_endpoint'] = $this->config->s3UsePathStyle;
        }

        if ($credentials !== null) {
            $args['credentials'] = $credentials;
        }

        $this->client = $client ?? new S3Client($args);
    }

    /**
     * JSON 文字列を S3 に PUT し、ETag を返す。
     */
    public function put(string $json): string
    {
        $result = $this->client->putObject([
            'Bucket' => $this->config->s3Bucket,
            'Key' => $this->config->s3Key(),
            'Body' => $json,
            'ContentType' => 'application/json; charset=utf-8',
        ]);

        return (string) ($result['ETag'] ?? '');
    }

    /** 表示用: アップロード先の s3:// 形式の URI */
    public function targetUri(): string
    {
        return sprintf('s3://%s/%s', $this->config->s3Bucket, $this->config->s3Key());
    }
}
