<?php

declare(strict_types=1);

namespace App;

use Aws\S3\S3Client;

/**
 * JSON を AWS S3 へアップロードする。
 *
 * 認証情報はこのクラスでは扱わない。$credentials が null なら AWS SDK の既定プロバイダチェーン
 * （環境変数 → 共有設定ファイル → ... ）に委ね、Cloud Run では GoogleWebIdentityCredentialProvider
 * （SA の ID トークン → STS AssumeRoleWithWebIdentity。鍵レス）を注入する（app/public/index.php）。
 */
final class S3Uploader
{
    private readonly S3Client $client;

    /**
     * @param callable|null $credentials AWS SDK のクレデンシャルプロバイダ（Credentials の Promise を返す callable）。null なら既定チェーン
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
     * JSON を S3 に PUT し、ETag を返す。
     *
     * @param string|resource $body JSON 文字列、または読み取り用のストリーム（大きな JSON をメモリに載せずに送る）
     * @param int|null        $contentLength ストリームのときはサイズを渡す（SDK がチャンク送信に切り替えないように）
     */
    public function put(mixed $body, ?int $contentLength = null): string
    {
        $args = [
            'Bucket' => $this->config->s3Bucket,
            'Key' => $this->config->s3Key(),
            'Body' => $body,
            'ContentType' => 'application/json; charset=utf-8',
        ];
        if ($contentLength !== null) {
            $args['ContentLength'] = $contentLength;
        }

        $result = $this->client->putObject($args);

        return (string) ($result['ETag'] ?? '');
    }

    /** 表示用: アップロード先の s3:// 形式の URI */
    public function targetUri(): string
    {
        return sprintf('s3://%s/%s', $this->config->s3Bucket, $this->config->s3Key());
    }
}
