# Skill: deploy-and-check

## 描述

在 auto-deploy Skill 完成 ECS 部署后，执行健康检查并整理可提交到答辩材料的部署证据。

## 触发场景

- auto-deploy 部署完成后；
- 修复 bug 后重新部署完成；
- 答辩前执行上线检查。

## 输入变量

```text
APP_URL=http://<Skill输出的公网IP>:3000
ENV_FILE=.env
```

## 指令

请对已部署的九曲云档应用执行验收检查：

1. 读取 `.auto-deploy/run-summary.json`，确认部署状态；
2. 检查 `.auto-deploy` 中是否生成：
   - `analysis.json`
   - `resource-spec.json`
   - `deployment-plan.md`
   - `deployment-test-report.md`
3. 依次请求：
   - `${APP_URL}/api/health`
   - `${APP_URL}/api/status`
   - `${APP_URL}/api/heritages?pageSize=1`
   - `${APP_URL}/api/chat`
4. 确认 `/api/status` 中：
   - `data.mode = huaweicloud-rds`
   - `services.rds.stats.connected = true`
   - `services.redis.ready = true`
   - `services.obs.configured = true`
   - `services.llm.configured = true`
5. 如任一检查失败，输出排查方向；
6. 生成一段可粘贴到答辩 PPT 的部署结果说明，并提醒截图保存。

## 期望输出

- 健康检查通过记录；
- `/api/status` 截图说明；
- 部署证据文件清单；
- 答辩用部署结果描述。
