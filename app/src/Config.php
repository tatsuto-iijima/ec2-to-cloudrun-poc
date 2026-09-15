<?php

declare(strict_types=1);

namespace App;

use InvalidArgumentException;

/**
 * 環境変数から読み取ったアプリ設定。
 *
 * EC2 では php.ini や Apache の SetEnv で渡していた値を、Cloud Run では環境変数で渡す前提。
 */
final class Config
{
    public const WRITE_MODE_LOCK = 'lock';
    public const WRITE_MODE_RENAME = 'rename';

    public function __construct(
        /** JSON マスタファイルを置くディレクトリ（Cloud Run では Cloud Storage ボリュームのマウント先） */
        public readonly string $dataDir,
        /** JSON マスタファイル名 */
        public readonly string $dataFile,
        /** 書き込み方式。lock = file_put_contents + LOCK_EX（現行アプリと同じ）、rename = 一時ファイル + rename */
        public readonly string $writeMode,
        /** アップロード先の S3 バケット */
        public readonly string $s3Bucket,
        /** S3 オブジェクトキーの接頭辞（例: "poc/"） */
        public readonly string $s3KeyPrefix,
        /** AWS リージョン */
        public readonly string $awsRegion,
        /** S3 互換エンドポイント（MinIO など）。null なら本物の S3 */
        public readonly ?string $s3Endpoint,
        /** パススタイルのエンドポイントを使うか（MinIO では true） */
        public readonly bool $s3UsePathStyle,
        /** Cloud Run の SA が引き受ける AWS IAM ロールの ARN。null なら SDK の既定チェーン（ローカルの moto 等） */
        public readonly ?string $awsRoleArn,
        /** ID トークンの audience（AWS 側の accounts.google.com:oaud）。既定はロールの ARN */
        public readonly ?string $awsWifAudience,
        /** AssumeRoleWithWebIdentity で得る一時クレデンシャルの有効期間（秒）。900〜ロールの max_session_duration */
        public readonly int $awsRoleDurationSeconds,
        /** STS 互換エンドポイント（ローカルの moto）。null なら本物の STS */
        public readonly ?string $stsEndpoint,
        /** メタデータサーバーのホスト。Google のクライアントライブラリと同じ GCE_METADATA_HOST で差し替えられる */
        public readonly string $metadataHost,
    ) {
        if (!in_array($this->writeMode, [self::WRITE_MODE_LOCK, self::WRITE_MODE_RENAME], true)) {
            throw new InvalidArgumentException(
                sprintf('WRITE_MODE は lock か rename を指定してください（指定値: %s）', $this->writeMode)
            );
        }
        if ($this->awsRoleDurationSeconds < 900) {
            throw new InvalidArgumentException(
                sprintf('AWS_ROLE_DURATION_SECONDS は 900 以上を指定してください（指定値: %d）', $this->awsRoleDurationSeconds)
            );
        }
    }

    /**
     * 環境変数から設定を組み立てる。
     */
    public static function fromEnv(): self
    {
        $endpoint = self::env('S3_ENDPOINT');
        $roleArn = self::env('AWS_ROLE_ARN');

        return new self(
            dataDir: self::env('DATA_DIR', '/mnt/data'),
            dataFile: self::env('DATA_FILE', 'data.json'),
            writeMode: self::env('WRITE_MODE', self::WRITE_MODE_LOCK),
            s3Bucket: self::env('S3_BUCKET', ''),
            s3KeyPrefix: self::env('S3_KEY_PREFIX', ''),
            awsRegion: self::env('AWS_REGION', 'ap-northeast-1'),
            s3Endpoint: $endpoint,
            // エンドポイント指定時（MinIO）は既定でパススタイル。明示指定があればそちらを優先
            s3UsePathStyle: self::envBool('S3_USE_PATH_STYLE', $endpoint !== null),
            awsRoleArn: $roleArn,
            // audience はロール ARN を既定にする（AWS 側の信頼ポリシー terraform/aws/iam.tf と揃える）
            awsWifAudience: self::env('AWS_WIF_AUDIENCE', $roleArn),
            awsRoleDurationSeconds: (int) self::env('AWS_ROLE_DURATION_SECONDS', '3600'),
            stsEndpoint: self::env('STS_ENDPOINT'),
            metadataHost: self::env('GCE_METADATA_HOST', 'metadata.google.internal'),
        );
    }

    /** JSON マスタファイルのフルパス */
    public function dataPath(): string
    {
        return rtrim($this->dataDir, '/') . '/' . $this->dataFile;
    }

    /** S3 の認証に WIF（Cloud Run の SA → AWS IAM ロール）を使うか */
    public function usesWebIdentity(): bool
    {
        return $this->awsRoleArn !== null;
    }

    /** S3 のオブジェクトキー */
    public function s3Key(): string
    {
        return $this->s3KeyPrefix . $this->dataFile;
    }

    /**
     * 環境変数を読む。未設定または空文字なら既定値を返す。
     */
    private static function env(string $name, ?string $default = null): ?string
    {
        $value = getenv($name);
        if ($value === false || $value === '') {
            return $default;
        }

        return $value;
    }

    private static function envBool(string $name, bool $default): bool
    {
        $value = self::env($name);
        if ($value === null) {
            return $default;
        }

        return filter_var($value, FILTER_VALIDATE_BOOLEAN);
    }
}
