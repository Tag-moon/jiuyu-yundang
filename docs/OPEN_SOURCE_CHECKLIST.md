# 开源准备清单

赛题说明指出：入围中国总决赛和全球总决赛的作品需开源至 Gitee、GitHub 等社区。建议现在就按此标准整理。

## 必须项

- [x] 项目源码：`apps/api/`、`web/`、`harmony-app/`
- [x] README：项目介绍、快速运行、演示流程
- [x] 架构说明：`docs/ARCHITECTURE.md`
- [x] 依赖环境：`apps/api/package.json`、`.env.example`
- [x] 部署指导：`docs/DEPLOYMENT_HUAWEI_CLOUD.md`
- [x] 开源许可证：`LICENSE`
- [x] Demo 截图：答辩前补充到 `docs/screenshots/`
- [x] 演示视频：答辩前录制并写链接
- [x] `.gitignore`：排除 `.env`、密钥、私钥、构建产物
- [ ] 图片与数据授权确认：见 `docs/DATA_SOURCES.md`

## 建议项

- [ ] GitHub/Gitee Actions：自动执行语法检查与接口冒烟测试
- [ ] API 自动化测试脚本
- [ ] CHANGELOG.md
- [ ] CONTRIBUTING.md
- [ ] 中英文 README
- [ ] 架构图源文件（drawio / mermaid）

## 发布前安全检查

- [ ] 全仓库搜索 `sk-`、`password`、`secret`、`token`，确认无真实密钥；
- [ ] 检查 Git 历史，必要时重写历史；
- [ ] `.env` 与 `.env.deploy` 未提交；
- [ ] RDS、Redis、OBS 账号使用最小权限；
- [ ] Demo 账号不含真实手机号或个人隐私；
- [ ] 第三方图片、数据、字体来源已确认可公开。

## 推荐仓库结构

```text
jiuyu-yundang-ict2026/
├── apps/
├── web/
├── harmony-app/
├── scripts/
├── docs/
├── codearts-skills/
├── LICENSE
├── README.md
└── .env.example
```
