<?php

declare(strict_types=1);

namespace App;

use Aws\Credentials\Credentials;
use Aws\Exception\AwsException;
use Aws\Exception\CredentialsException;
use Aws\Sts\StsClient;
use GuzzleHttp\Client as HttpClient;
use GuzzleHttp\Promise\Create;
use GuzzleHttp\Promise\PromiseInterface;
use RuntimeException;

/**
 * Cloud Run のサービスアカウントで AWS の IAM ロールを引き受けるクレデンシャルプロバイダ（鍵レス）。
 *
 * 流れ:
 *   1. メタデータサーバーからサービスアカウントの OIDC ID トークンを取得する
 *      （GET http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/identity?audience=...）
 *   2. AWS STS AssumeRoleWithWebIdentity にそのトークンを渡し、一時クレデンシャルを得る
 *   3. 一時クレデンシャルを /tmp にキャッシュし、期限が近づいたら取り直す
 *
 * AWS SDK 同梱の AssumeRoleWithWebIdentityCredentialProvider はトークンをファイルからしか読めないため、
 * その実装を参考に自前で書いている。呼び出し規約（callable が Credentials の Promise を返す）は SDK と同じなので、
 * S3Client の 'credentials' にそのまま渡せる（S3Uploader のコンストラクタ経由）。
 *
 * mod_php ではリクエストごとに PHP のプロセスが入れ替わるので、プロセス内のメモ化だけでは毎回 STS を呼んでしまう。
 * そのためファイルキャッシュを使う（Cloud Run の /tmp はインスタンス内のインメモリ領域。インスタンスが消えれば一緒に消える）。
 */
final class GoogleWebIdentityCredentialProvider
{
    /** 期限までこの秒数を切ったら取り直す */
    private const REFRESH_MARGIN_SECONDS = 300;

    /** STS の InvalidIdentityToken（発行直後の時計ずれ等）のリトライ回数 */
    private const MAX_ATTEMPTS = 3;

    private readonly string $cacheFile;

    public function __construct(
        private readonly Config $config,
        ?string $cacheFile = null,
        private ?StsClient $stsClient = null,
        private ?HttpClient $httpClient = null,
    ) {
        if ($this->config->awsRoleArn === null) {
            throw new RuntimeException('AWS_ROLE_ARN が未設定です');
        }
        $this->cacheFile = $cacheFile ?? sys_get_temp_dir() . '/aws-wif-credentials.json';
    }

    /**
     * AWS SDK のクレデンシャルプロバイダとして呼ばれる。
     */
    public function __invoke(): PromiseInterface
    {
        $cached = $this->readCache();
        if ($cached !== null) {
            return Create::promiseFor($cached);
        }

        $credentials = $this->assumeRole($this->fetchIdToken());
        $this->writeCache($credentials);

        error_log(sprintf(
            'wif: credentials refreshed role=%s expires=%s',
            $this->config->awsRoleArn,
            gmdate(DATE_ATOM, (int) $credentials->getExpiration())
        ));

        return Create::promiseFor($credentials);
    }

    /**
     * メタデータサーバーからサービスアカウントの ID トークンを取得する。
     * format=full で email クレームも含める（AWS 側の条件には使わないが、トラブル時にトークンの中身を確認しやすい）。
     */
    public function fetchIdToken(): string
    {
        $url = sprintf(
            'http://%s/computeMetadata/v1/instance/service-accounts/default/identity?%s',
            $this->config->metadataHost,
            http_build_query(['audience' => $this->config->awsWifAudience, 'format' => 'full'])
        );

        try {
            $response = $this->http()->get($url, [
                'headers' => ['Metadata-Flavor' => 'Google'],
                'timeout' => 3,
                'connect_timeout' => 1,
            ]);
        } catch (\Throwable $e) {
            throw new CredentialsException(
                sprintf('メタデータサーバーから ID トークンを取得できません（%s）: %s', $this->config->metadataHost, $e->getMessage()),
                0,
                $e
            );
        }

        $token = trim((string) $response->getBody());
        if ($token === '') {
            throw new CredentialsException('メタデータサーバーが空の ID トークンを返しました');
        }

        return $token;
    }

    /**
     * STS AssumeRoleWithWebIdentity で一時クレデンシャルを得る。
     */
    private function assumeRole(string $idToken): Credentials
    {
        $params = [
            'RoleArn' => $this->config->awsRoleArn,
            'RoleSessionName' => 'cloudrun-' . gethostname() . '-' . time(),
            'WebIdentityToken' => $idToken,
            'DurationSeconds' => $this->config->awsRoleDurationSeconds,
        ];

        $client = $this->sts();
        for ($attempt = 1; ; $attempt++) {
            try {
                $result = $client->assumeRoleWithWebIdentity($params);
                break;
            } catch (AwsException $e) {
                // 発行直後のトークンは STS 側の時計ずれで拒否されることがあるので少し待って再試行する
                if ($e->getAwsErrorCode() === 'InvalidIdentityToken' && $attempt < self::MAX_ATTEMPTS) {
                    sleep($attempt);
                    continue;
                }
                throw new CredentialsException(
                    sprintf('AssumeRoleWithWebIdentity に失敗しました（%s）: %s', $e->getAwsErrorCode() ?? 'unknown', $e->getAwsErrorMessage() ?? $e->getMessage()),
                    0,
                    $e
                );
            }
        }

        $c = $result['Credentials'];

        return new Credentials(
            (string) $c['AccessKeyId'],
            (string) $c['SecretAccessKey'],
            (string) $c['SessionToken'],
            $c['Expiration'] instanceof \DateTimeInterface ? $c['Expiration']->getTimestamp() : (int) strtotime((string) $c['Expiration'])
        );
    }

    /**
     * キャッシュに期限まで余裕のある一時クレデンシャルがあれば返す。
     */
    private function readCache(): ?Credentials
    {
        $raw = @file_get_contents($this->cacheFile);
        if ($raw === false) {
            return null;
        }

        $data = json_decode($raw, true);
        if (!is_array($data) || !isset($data['key'], $data['secret'], $data['token'], $data['expires'])) {
            return null;
        }

        // 別のロールのキャッシュは使わない（環境変数を切り替えたときの取り違え防止）
        if (($data['role'] ?? null) !== $this->config->awsRoleArn) {
            return null;
        }

        if ((int) $data['expires'] - time() < self::REFRESH_MARGIN_SECONDS) {
            return null;
        }

        return new Credentials((string) $data['key'], (string) $data['secret'], (string) $data['token'], (int) $data['expires']);
    }

    /**
     * 一時クレデンシャルをキャッシュに書く。一時ファイルに書いて rename し、読み手が途中の内容を見ないようにする。
     * 書けなくても致命ではない（次のリクエストで取り直すだけ）ので、失敗はログに残して続行する。
     */
    private function writeCache(Credentials $credentials): void
    {
        $tmp = $this->cacheFile . '.' . getmypid() . '.tmp';
        $json = json_encode([
            'role' => $this->config->awsRoleArn,
            'key' => $credentials->getAccessKeyId(),
            'secret' => $credentials->getSecretKey(),
            'token' => $credentials->getSecurityToken(),
            'expires' => $credentials->getExpiration(),
        ]);

        if (@file_put_contents($tmp, $json) === false || !@chmod($tmp, 0600) || !@rename($tmp, $this->cacheFile)) {
            @unlink($tmp);
            error_log(sprintf('wif: credentials cache write failed: %s', $this->cacheFile));
        }
    }

    private function sts(): StsClient
    {
        if ($this->stsClient === null) {
            $args = [
                'version' => 'latest',
                'region' => $this->config->awsRegion,
                // STS 自体は認証なしで呼ぶ（AssumeRoleWithWebIdentity は署名不要）
                'credentials' => false,
                // グローバルエンドポイントではなく、S3 と同じリージョンの STS を使う
                'sts_regional_endpoints' => 'regional',
            ];
            if ($this->config->stsEndpoint !== null) {
                $args['endpoint'] = $this->config->stsEndpoint;
            }
            $this->stsClient = new StsClient($args);
        }

        return $this->stsClient;
    }

    private function http(): HttpClient
    {
        return $this->httpClient ??= new HttpClient();
    }
}
