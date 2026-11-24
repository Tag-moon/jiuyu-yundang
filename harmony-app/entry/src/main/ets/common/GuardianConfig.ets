/**
 * 九曲云档 —— 云服务配置
 * 部署到华为云后，把 CLOUD_ENDPOINT 替换为实际 API 域名，例如：
 * https://jiuyu-api.your-domain.com/api
 */
export class GuardianConfig {
  /** 云上 API 地址。本地联调可填 http://<电脑IP>:3000/api */
  static readonly CLOUD_ENDPOINT: string = 'https://replace-with-your-cloud-domain/api';

  /** 保留旧键名仅用于兼容历史数据，不再使用第三方大模型密钥 */
  static readonly LEGACY_KEY_META: string = 'guardian_key';

  static readonly SUGGESTIONS: string[] = [
    '龙门石窟有什么看点',
    '推荐一条洛阳一日路线',
    '仰韶文化是什么意思',
    '殷墟为什么重要'
  ];

  static isCloudConfigured(): boolean {
    return GuardianConfig.CLOUD_ENDPOINT.indexOf('replace-with') < 0;
  }
}
