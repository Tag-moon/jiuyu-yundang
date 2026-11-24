# Skill: cloud-bootstrap

## 描述

根据项目需求生成华为云资源开通清单、安全组规则、VPC 规划与环境变量模板。

## 触发场景

- 需要关联 RDS、Redis、OBS；
- 需要把应用部署到 ECS；
- 需要生成赛题演示用的云资源拓扑。

## 输入变量

```text
PROJECT_NAME=jiuyu-yundang
REGION=cn-north-4
VPC_CIDR=192.168.0.0/16
RDS_ENGINE=MySQL8.0
REDIS_VERSION=6.0
ECS_OS=Ubuntu22.04
```

## 指令

你是华为云解决方案架构师。请为「九曲云档」赛题一 Demo 生成一份最小可用云资源方案，包含：

1. VPC、子网、安全组规划；
2. ECS 规格与开放端口；
3. RDS for MySQL 实例、数据库名、账号权限；
4. Redis/DCS 实例规格与连接方式；
5. OBS 桶命名与图片目录；
6. `.env` 中需要填写的变量清单；
7. 成本-conscious 的最小配置建议。

要求：
- RDS 和 Redis 不开放公网；
- ECS 与 RDS/Redis 同 VPC；
- 所有密钥只能通过环境变量传递；
- 输出 Markdown 表格，方便复制到部署文档。

## 期望输出

- `docs/CLOUD_RESOURCE_PLAN.md`
- `.env.example` 更新建议
- 华为云控制台配置步骤清单
