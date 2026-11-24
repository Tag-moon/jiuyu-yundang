# HarmonyOS 端改动说明

改造后的源码位于 `harmony-app/`，可直接在 DevEco Studio 中打开。

## 已改动文件

| 文件 | 改动 |
|---|---|
| `entry/src/main/ets/common/GuardianConfig.ets` | 删除硬编码第三方 API Key；新增 `CLOUD_ENDPOINT` 与 `isCloudConfigured()` |
| `entry/src/main/ets/datasource/CloudApiService.ets` | 新增云上 API 访问层：档案、问答、云同步 |
| `entry/src/main/ets/datasource/CloudSyncService.ets` | 新增云端同步：按版本号和墓碑合并收藏、笔记、足迹 |
| `entry/src/main/ets/datasource/GuardianService.ets` | 改为云侧问答代理，不再直接调用第三方大模型；回答附带档案来源 |
| `entry/src/main/ets/datasource/HeritageRepository.ets` | 云优先加载档案，云端未配置或失败时回退 rawfile |
| `entry/src/main/ets/pages/Guardian.ets` | 删除密钥设置弹窗和本地密钥输入；改为云服务状态展示 |
| `entry/src/main/ets/entryability/EntryAbility.ets` | 前台自动同步时增加云端版本化合并 |

## 部署前必须修改

打开：

```text
entry/src/main/ets/common/GuardianConfig.ets
```

把：

```ts
static readonly CLOUD_ENDPOINT: string = 'https://replace-with-your-cloud-domain/api';
```

改成云上 API 地址，例如：

```ts
static readonly CLOUD_ENDPOINT: string = 'https://jiuyu-api.example.com/api';
```

本地联调可使用：

```ts
static readonly CLOUD_ENDPOINT: string = 'http://<电脑局域网IP>:3000/api';
```

## 验证方式

1. DevEco Studio 打开 `harmony-app`；
2. 确认 `ohos.permission.INTERNET` 已声明（原项目已有）；
3. 编译并安装到设备；
4. 进入「黄河守护灵」提问，云端配置正确时应返回答案与档案来源；
5. 回到前台时会自动执行一次云端同步。

## 安全说明

旧版本中的 `sk-...` 密钥已从改造版源码中删除。请同时在原密钥平台吊销该 Key，并检查原始源码包是否曾上传到公开仓库。
