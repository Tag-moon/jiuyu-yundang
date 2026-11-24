# CodeArts Skills 示例

本目录提供面向赛题一的 Skills 示例与调用模板，用于体现「基于已有智能体和 Skills 进行云资源关联与快速部署」。

| Skill / 模板 | 作用 |
|---|---|
| `cloud-bootstrap` | 生成华为云 RDS、Redis、OBS 的开通与配置清单 |
| `heritage-data-import` | 把 `heritages.json` 转成 RDS 建表和导入脚本 |
| `cloud-api-scaffold` | 生成或扩展云上 API 接口 |
| `auto-deploy` | 调用官方 auto-deploy Skill，一键创建 ECS 并部署应用 |
| `deploy-and-check` | 部署后健康检查与证据整理 |

## 推荐部署链路

赛题一推荐使用 `auto-deploy` Skill：

```text
自然语言部署需求
→ 项目分析
→ 部署计划
→ ECS/EIP/安全组自动创建
→ 代码上传
→ 应用启动
→ 健康检查
→ 报告输出
```

官方 auto-deploy Skill 仓库：

```text
https://gitcode.com/weixin_43883336/auto-deploy
```

详细案例见：

```text
docs/auto-deploy-case-study.md
docs/AUTO_DEPLOY_GUIDE.md
```

## 使用方式

1. 在 CodeArts 智能体中新建或安装 Skill；
2. 复制对应 `SKILL.md` 中的指令；
3. 按实际情况填写参数；
4. 运行后把输出与截图保存到 `docs/CODEARTS_EVIDENCE.md`。

> `cloud-bootstrap`、`heritage-data-import`、`cloud-api-scaffold`、`deploy-and-check` 是本项目沉淀的工程 SOP；`auto-deploy` 是调用官方一键部署能力的集成模板。
