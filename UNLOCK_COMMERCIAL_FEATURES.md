# PostHog 开源版解锁商业版功能 — 开发计划与实施监督文档

> 创建日期: 2026-03-30
> 最后更新: 2026-03-30
> 状态: P0/P1 已完成，P2/P4 已验证无需改动

---

## 一、项目概述

PostHog 采用 Open Core 模式，所有付费功能代码都在开源仓库的 `ee/` 目录中（820 个 Python 文件，18MB）。功能限制仅通过 `organization.is_feature_available()` 检查实现。本文档整理所有需要修改的位置，按优先级分阶段执行，确保每步改完项目可正常编译部署。

**实施策略**: 采用 `customizations/` Django App 补丁层模式，通过 monkey-patch 注入修改，最大程度减少对 PostHog 原始代码的侵入，降低上游同步时的合并冲突。

---

## 二、实施进度总览

| 阶段 | 内容 | 改动量 | 风险 | 状态 | 完成日期 |
|------|------|--------|------|------|---------|
| **P0** | 核心开关：解锁全部功能 | 4 新文件 + 1 行注册 | 极低 | ✅ 已完成 | 2026-03-30 |
| **P1** | 前端 PayGate 清理：移除付费墙 UI | 3 个文件精准修改 | 低 | ✅ 已完成 | 2026-03-30 |
| **P2** | 数量限制解除：告警、项目、并发 | 0 (P0 自动覆盖) | — | ✅ 无需改动 | 2026-03-30 |
| **P3** | 权限/安全功能适配：SAML/SCIM/RBAC | 配置级 | 中 | ⬜ 待开始 | — |
| **P4** | Billing 解耦：去除外部计费依赖 | 0 (自部署自动跳过) | — | ✅ 无需改动 | 2026-03-30 |
| **P5** | 端到端验证 | 0 改动 | — | ⬜ 待验证 | — |

> 状态标记: ⬜ 待开始 | 🔵 进行中 | ✅ 已完成 | ❌ 受阻

---

## 三、实施架构 — customizations/ 补丁层

### 设计理念

采用独立 Django App + monkey-patch 模式，而非直接修改 PostHog 原始文件。优势：
- **上游同步冲突最小化**: PostHog 原始文件几乎不改，`git merge upstream/master` 时冲突接近零
- **改动集中可控**: 所有定制逻辑集中在 `customizations/` 目录，便于审查和维护
- **可逆性强**: 删除 `customizations/` 并撤销 INSTALLED_APPS 注册即可恢复原状

### 文件结构

```
customizations/
├── __init__.py                          # Django app 包
├── apps.py                              # AppConfig，ready() 中应用补丁
└── patches/
    ├── __init__.py                      # patches 包
    └── unlock_features.py               # P0: monkey-patch 解锁全部功能
```

### 注册方式

在 `posthog/settings/web.py` 的 `INSTALLED_APPS` 末尾添加：
```python
"customizations.apps.CustomizationsConfig",
```

### 补丁加载流程

```
Django 启动 → INSTALLED_APPS 加载 → CustomizationsConfig.ready()
    → unlock_features.apply()
        → Organization.update_available_product_features = patched_version
```

---

## 四、P0: 核心开关 — 解锁全部功能 ✅ 已完成

> **目标**: 改完这一步，所有后端 API 层面的功能限制即解除。项目可正常编译部署。

### 实际实现

| 文件 | 操作 | 状态 |
|------|------|------|
| `customizations/__init__.py` | 新建 — Django app 包 | ✅ |
| `customizations/apps.py` | 新建 — AppConfig，`ready()` 中调用补丁 | ✅ |
| `customizations/patches/__init__.py` | 新建 — patches 包 | ✅ |
| `customizations/patches/unlock_features.py` | 新建 — monkey-patch 核心逻辑 | ✅ |
| `posthog/settings/web.py` | 修改 — INSTALLED_APPS 注册 | ✅ |

### 核心补丁代码 (`customizations/patches/unlock_features.py`)

```python
def _patched_update_available_product_features(self):
    from posthog.constants import AvailableFeature
    self.available_product_features = [
        {"key": feature.value, "name": feature.value.replace("_", " ").capitalize()}
        for feature in AvailableFeature
    ]
    return self.available_product_features

def apply():
    from posthog.models.organization import Organization
    Organization.update_available_product_features = _patched_update_available_product_features
```

### 原理
- `is_feature_available()` 和 `get_available_feature()` 都读取 `available_product_features` 字段
- 所有后端 35+ 处 `is_feature_available()` 调用自动全部通过
- 所有前端通过 API 获取的 `available_product_features` 也会包含全部功能
- Celery 定时任务 `sync_all_organization_available_product_features`（每小时执行）调用的也是这个被 patch 的方法，自动将全部功能持久化到数据库
- 不改动 License 模型，不影响现有数据结构

### 验证清单
- [ ] `python manage.py check` 通过
- [ ] `python manage.py runserver` 正常启动
- [ ] GET `/api/organizations/@current/` 返回的 `available_product_features` 包含全部 38 个功能
- [ ] 基础 Insight (Trends/Funnels/Retention) 正常工作

### 影响的后端检查点（全部自动通过，无需逐个修改）

| 文件 | 检查的功能 | 作用 |
|------|-----------|------|
| `ee/api/authentication.py:115` | SAML | SAML IdP 查找 |
| `ee/api/scim/auth.py:60` | SCIM | SCIM 认证 |
| `posthog/api/data_color_theme.py:38` | DATA_COLOR_THEMES | 自定义配色 |
| `posthog/api/organization.py:56` | ORGANIZATIONS_PROJECTS | 多项目 |
| `posthog/api/organization.py:193` | ORGANIZATION_INVITE_SETTINGS | 邀请设置 |
| `posthog/api/organization.py:202` | TWO_FACTOR_ENFORCEMENT | 2FA 强制 |
| `posthog/api/organization.py:211,220` | ORGANIZATION_SECURITY_SETTINGS | 安全设置 |
| `posthog/api/organization_domain.py:101,131,138` | AUTOMATIC_PROVISIONING, SCIM | 域名管理 |
| `posthog/api/sharing.py:134,360,451,490,604,647,910` | ADVANCED_PERMISSIONS, SECURITY, WHITE_LABELLING | 共享控制 |
| `posthog/api/team.py:406` | DATA_COLOR_THEMES | Team 配色 |
| `posthog/api/query.py:137` | API_QUERIES_CONCURRENCY | 查询并发 |
| `posthog/approvals/decorators.py:57` | APPROVALS | 审批流 |
| `posthog/rbac/user_access_control.py:338,345` | ROLE_BASED_ACCESS, ADVANCED_PERMISSIONS | RBAC |
| `posthog/user_permissions.py:194,286` | ADVANCED_PERMISSIONS | 用户权限 |
| `posthog/models/user.py:349` | ADVANCED_PERMISSIONS | 角色分配 |
| `posthog/models/alert.py:168` | ALERTS | 告警限制 |
| `posthog/api/project.py:995` | ORGANIZATIONS_PROJECTS | 项目限制 |
| `posthog/api/proxy_record.py:116` | MANAGED_REVERSE_PROXY | 反向代理 |
| `posthog/api/team.py:1208` | SESSION_REPLAY_DATA_RETENTION | 录屏保留 |
| `posthog/api/advanced_activity_logs/utils.py:14` | AUDIT_LOGS | 审计日志 |
| `posthog/clickhouse/client/limit.py:446` | ORGANIZATION_APP_QUERY_CONCURRENCY_LIMIT | 应用并发 |
| `posthog/hogql_queries/query_runner.py:1476` | API_QUERIES_CONCURRENCY | 查询并发 |
| `products/surveys/backend/api/survey.py:677` | WHITE_LABELLING | Survey 白标 |
| `ee/hogai/context/context.py:139` | AUDIT_LOGS | AI 审计上下文 |
| `ee/api/subscription.py:241` | SUBSCRIPTIONS (PremiumFeaturePermission) | 邮件订阅 |
| `posthog/approvals/api.py:51,164` | APPROVALS (PremiumFeaturePermission) | 审批 API |

---

## 五、P1: 前端 PayGate 清理 — 移除付费墙 UI ✅ 已完成

> **目标**: 清理前端残留的付费墙组件，确保用户体验无付费提示。

### 实际实现

| 文件 | 修改内容 | 状态 |
|------|---------|------|
| `frontend/src/scenes/userLogic.ts` | `hasAvailableFeature` 始终返回 `true` | ✅ |
| `frontend/src/lib/components/PayGateMini/payGateMiniLogic.tsx` | `gateVariant` 始终返回 `null` | ✅ |
| `frontend/src/lib/components/UpgradeModal/upgradeModalLogic.ts` | `guardAvailableFeature` 直接执行回调 | ✅ |

### 1.1 hasAvailableFeature — 始终返回 true

**文件**: `frontend/src/scenes/userLogic.ts`

```typescript
hasAvailableFeature: [
    (s) => [s.user],
    (_user) => {
        // [CUSTOMIZATION] All features unlocked for self-hosted commercial build
        return (_feature: AvailableFeature, _currentUsage?: number) => {
            return true
        }
    },
],
```

**解决的关键问题**: 前端 `types.ts` 定义了 117+ 个 AvailableFeature（比后端 38 个多得多），如 `SURVEYS_UNLIMITED_SURVEYS`, `CONSOLE_LOGS`, `MOBILE_REPLAY` 等由 Billing Service 动态下发。直接返回 `true` 一步到位覆盖所有前端功能检查。

### 1.2 gateVariant — 始终返回 null

**文件**: `frontend/src/lib/components/PayGateMini/payGateMiniLogic.tsx`

```typescript
gateVariant: [
    (s) => [
        s.billingLoading,
        s.hasAvailableFeature,
        s.minimumPlanWithFeature,
        (_, props) => props.feature,
        (_, props) => props.currentUsage,
    ],
    // [CUSTOMIZATION] Always return null — no paywall gates
    () => {
        return null
    },
],
```

**自动影响的所有 PayGateMini 使用位置**（无需逐个修改）：

| 文件 | 被保护的功能 |
|------|-------------|
| `scenes/surveys/wizard/steps/AppearanceStep.tsx` | Surveys 样式 |
| `scenes/surveys/survey-appearance/SurveyAppearanceModal.tsx` | Survey 外观 |
| `scenes/surveys/survey-appearance/SurveyCustomization.tsx` | Survey 自定义 |
| `scenes/insights/views/Funnels/FunnelCorrelation.tsx` | 漏斗相关性分析 |
| `scenes/groups/GroupsIntroduction.tsx` | Group Analytics |
| `scenes/audit-logs/AdvancedActivityLogsScene.tsx` | 审计日志 |
| `scenes/settings/organization/OrganizationSecuritySettings.tsx` | 安全设置 |
| `scenes/settings/environment/ReplayTriggers.tsx` | Replay 触发器 |

### 1.3 guardAvailableFeature — 直接执行回调

**文件**: `frontend/src/lib/components/UpgradeModal/upgradeModalLogic.ts`

```typescript
guardAvailableFeature: [
    (s) => [s.preflight, s.hasAvailableFeature],
    (): GuardAvailableFeatureFn => {
        // [CUSTOMIZATION] Always grant access — no upgrade modal
        return (_featureKey, featureAvailableCallback): boolean => {
            featureAvailableCallback?.()
            return true
        }
    },
],
```

**自动影响的所有 guardAvailableFeature 使用位置**：

| 文件 | 被保护的功能 |
|------|-------------|
| `scenes/surveys/wizard/steps/AppearanceStep.tsx` | WHITE_LABELLING |
| `lib/components/Account/OrgSwitcher.tsx` | ORGANIZATIONS_PROJECTS |
| `lib/components/Account/ProjectSwitcher.tsx` | ORGANIZATIONS_PROJECTS |
| `lib/components/Account/ProjectCombobox.tsx` | ORGANIZATIONS_PROJECTS |
| `lib/components/Account/OrgCombobox.tsx` | ORGANIZATIONS_PROJECTS |
| `lib/components/Account/NewAccountMenu.tsx` | ORGANIZATIONS_PROJECTS |

### 1.4 无需修改（已验证）

| 文件 | 说明 |
|------|------|
| `frontend/src/lib/lemon-ui/LemonLabel/LemonLabel.tsx` | `premiumFeature` prop，P0+P1 后自动不显示锁图标 |
| `frontend/src/lib/lemon-ui/LemonField/LemonField.tsx` | 同上 |

### 验证清单
- [ ] `pnpm --filter=@posthog/frontend build` 编译通过
- [ ] `pnpm --filter=@posthog/frontend typescript:check` 类型检查通过
- [ ] `pnpm --filter=@posthog/frontend test` 测试通过
- [ ] Surveys 编辑页无付费提示
- [ ] Funnels 相关性面板正常显示
- [ ] Groups 页面无付费提示
- [ ] 创建新 Project 无弹窗阻挡
- [ ] 审计日志页面正常显示

---

## 六、P2: 数量限制解除 ✅ 无需改动

> **结论**: P0 补丁返回的 feature dict 不含 `limit` 字段，各处限制检查逻辑默认走"无限制"路径，无需额外代码修改。

### 分析详情

| 限制项 | 文件 | 原始逻辑 | P0 后行为 | 状态 |
|--------|------|---------|-----------|------|
| 告警数量 (5条) | `posthog/models/alert.py:166-181` | `get_available_feature(ALERTS)` → 检查 `limit` | 返回 dict 无 `limit` → `allowed = None` → 无限制 | ✅ |
| API 并发查询 | `posthog/hogql_queries/query_runner.py:1476` | 检查 `API_QUERIES_CONCURRENCY` 的 `limit` | 无 `limit` → 使用默认并发 | ✅ |
| 应用并发 | `posthog/clickhouse/client/limit.py:446` | 检查 `ORGANIZATION_APP_QUERY_CONCURRENCY_LIMIT` | 无 `limit` → 使用默认值 | ✅ |
| 项目数量 | `posthog/api/project.py:995` | 检查 `ORGANIZATIONS_PROJECTS` 的 `limit` | 无 `limit` → 无限制 | ✅ |
| Replay 保留时长 | `posthog/api/team.py:1208` | 检查 `SESSION_REPLAY_DATA_RETENTION` 的 `limit` | 无 `limit` → 不强制缩短 | ✅ |

### 关键代码路径（以告警为例）

```python
# posthog/models/alert.py:166-181
def check_alert_limit(cls, team_id, organization):
    alerts_feature = organization.get_available_feature(AvailableFeature.ALERTS)
    # P0 后: alerts_feature = {"key": "alerts", "name": "Alerts"} (无 limit 字段)
    if alerts_feature:
        allowed = alerts_feature.get("limit")  # → None
        if allowed is not None and existing_count >= allowed:  # None is not None → False
            return error_message
        # → 跳过限制，返回 None（无限制）
```

---

## 七、P3: 权限/安全功能适配 ⬜ 待开始

> **目标**: 这些功能代码已解锁，但需要配置外部依赖才能真正工作。

### 3.1 SAML 认证

| 项目 | 详情 | 状态 |
|------|------|------|
| 代码位置 | `ee/api/authentication.py` (~行 115) | — |
| 配置 | 设置 `SOCIAL_AUTH_SAML_*` 环境变量（`ee/settings.py`） | ⬜ |
| 依赖 | 需要 SAML IdP (Okta/OneLogin/Azure AD) | ⬜ |
| 数据库 | 创建 `OrganizationDomain` 记录 | ⬜ |

**无需改代码**，只需配置。

### 3.2 SCIM 用户同步

| 项目 | 详情 | 状态 |
|------|------|------|
| 代码位置 | `ee/api/scim/` 目录 | — |
| 配置 | IdP 中配置 SCIM endpoint，生成 Bearer Token | ⬜ |

**无需改代码**，只需配置。

### 3.3 RBAC 角色权限

| 项目 | 详情 | 状态 |
|------|------|------|
| 核心逻辑 | `posthog/rbac/user_access_control.py` (~1078 行) | — |
| 模型 | `ee/models/rbac/access_control.py`, `role.py` | — |

**P0 完成后自动可用**，可在 Settings > Access Control 中创建角色。

### 3.4 SSO 强制 / 2FA 强制 / 审计日志

**P0 完成后均自动可用**，在 Organization Settings 中开启即可。

### 验证清单
- [ ] Settings > Access Control 页面正常，可创建角色
- [ ] Settings > Audit Logs 页面正常显示
- [ ] `pytest ee/api/test/ -x` 通过
- [ ] SAML/SCIM: 需实际 IdP 配合测试（可后续进行）

---

## 八、P4: Billing 解耦 ✅ 无需改动

> **结论**: 自部署环境 `is_cloud()` 返回 False，Billing 相关逻辑自动跳过，无需代码修改。

### 分析详情

| 检查点 | 文件 | 结论 |
|--------|------|------|
| Billing Manager | `ee/billing/billing_manager.py` | 自部署不主动调用 billing API | ✅ |
| Billing API | `ee/api/billing.py` | 需要 License + Cloud 环境才触发 | ✅ |
| License Sync 信号 | `ee/models/license.py:117-119` | post_save 调用 P0 patch 过的方法，写入全部功能 | ✅ |
| Celery 定时同步 | `posthog/tasks/sync_all_organization_available_product_features.py` | 每小时执行，调用 P0 patch 方法，自动持久化 | ✅ |
| Preflight 检查 | `posthog/views.py` | `is_cloud()` = False，billing 逻辑跳过 | ✅ |
| BILLING_SERVICE_URL | `ee/settings.py:79` | 默认值 `https://billing.posthog.com`，但自部署不调用 | ✅ |

### Celery 持久化流程

```
每小时 crontab → sync_all_organization_available_product_features()
    → 遍历所有 Organization
        → org.update_available_product_features()  # ← 已被 P0 monkey-patch
        → org.save()  # 全部 38 个功能写入数据库
```

---

## 九、P5: 端到端验证 ⬜ 待执行

### 编译部署验证
```bash
python manage.py check                             # Django 系统检查
python manage.py migrate --check                   # 确认无待执行迁移
pnpm --filter=@posthog/frontend build              # 前端编译
pnpm --filter=@posthog/frontend typescript:check   # TypeScript 类型检查
```

### 功能验证矩阵

| 功能 | 验证方式 | 对应阶段 | 通过 |
|------|---------|---------|------|
| 全部功能标记可用 | GET `/api/organizations/@current/` 检查 `available_product_features` | P0 | ⬜ |
| Trends/Funnels/Retention | 创建 Insight，各类型能选择 | P0 | ⬜ |
| 漏斗相关性分析 | Funnels Insight 中出现 Correlation 面板 | P0+P1 | ⬜ |
| 高级路径分析 | Paths Insight 中出现高级选项 | P0+P1 | ⬜ |
| Group Analytics | 左侧导航出现 Groups，可创建 Group | P0+P1 | ⬜ |
| 行为群组 | Cohorts 中可选行为序列条件 | P0 | ⬜ |
| Session Replay 播放列表 | Replay 页面可创建播放列表 | P0+P1 | ⬜ |
| Session Replay 导出 | 单条录屏可导出文件 | P0 | ⬜ |
| Session Replay 性能 | 录屏详情出现 Performance 标签 | P0 | ⬜ |
| Surveys 多问题 | 创建 Survey 可添加多个问题 | P0 | ⬜ |
| Surveys 自定义样式 | Survey 编辑出现 Appearance 选项 | P0+P1 | ⬜ |
| 邮件订阅 | Dashboard 出现 Subscribe 按钮 | P0 | ⬜ |
| 告警 > 5 条 | 可创建超过 5 条告警 | P0 (自动) | ⬜ |
| 多项目 | 可创建新 Project，无弹窗 | P0+P1 | ⬜ |
| RBAC | Settings > Access Control 可创建角色 | P0+P3 | ⬜ |
| 审计日志 | Settings > Audit Logs 可查看记录 | P0+P1 | ⬜ |
| 白标 | Survey 可去除 PostHog 品牌标识 | P0 | ⬜ |
| Zapier 集成 | CDP 页面可配置 Zapier | P0 | ⬜ |
| Data Pipelines | CDP 页面完整可用 | P0 | ⬜ |
| 自定义配色 | Dashboard 可选自定义色彩主题 | P0 | ⬜ |

### 自动化测试
```bash
# 后端核心测试
pytest posthog/models/test/ -x
pytest posthog/api/test/ -x
pytest ee/api/test/ -x

# 前端测试
pnpm --filter=@posthog/frontend test

# 特定功能测试
pytest posthog/hogql_queries/insights/test/ -x    # Insights 查询
pytest products/surveys/backend/tests/ -x          # Surveys
pytest products/alerts/backend/ -x                 # Alerts
```

---

## 十、风险提示与注意事项

### 1. 版本升级风险 ⚠️
PostHog 频繁更新，`AvailableFeature` 枚举会新增功能。P0 的方案通过遍历枚举自动包含新增功能，**不受版本升级影响**。但如果 PostHog 改变 feature gating 架构，需重新适配。

**应对**: 每次升级 PostHog 版本前，检查 `posthog/models/organization.py` 的 `update_available_product_features` 方法是否有变化。

### 2. Feature Limit 字段 ✅ 已验证
P0 方案让功能"可用"且 `limit` 字段为空。经 P2 阶段验证，所有 limit 检查点在 `limit=None` 时均默认走"无限制"路径。

### 3. 前端 AvailableFeature 不同步 ✅ 已解决
前端定义了 117+ 个功能 key（比后端 38 个多得多）。已通过 P1 阶段修改 `userLogic.ts` 的 `hasAvailableFeature` 直接返回 `true` 一步到位解决。

### 4. Celery 定时任务 ✅ 已验证
`sync_all_organization_available_product_features` 每小时运行。P0 修改的是该任务调用的方法本身（monkey-patch），**不会被覆盖**，反而会自动将全部功能持久化到数据库。

### 5. 上游合并冲突 ⚠️
采用 `customizations/` 补丁层后，可能产生冲突的文件仅 4 个：

| 文件 | 冲突可能性 | 原因 |
|------|-----------|------|
| `posthog/settings/web.py` | 低 | 仅添加一行 INSTALLED_APPS 注册 |
| `frontend/src/scenes/userLogic.ts` | 中 | 修改了 `hasAvailableFeature` selector |
| `frontend/src/lib/components/PayGateMini/payGateMiniLogic.tsx` | 低 | 修改了 `gateVariant` selector |
| `frontend/src/lib/components/UpgradeModal/upgradeModalLogic.ts` | 低 | 修改了 `guardAvailableFeature` selector |

**应对**: 每次 `git merge upstream/master` 后检查这 4 个文件，冲突解决方式均为保留我们的定制版本。

### 6. 法律合规 ⚠️
PostHog EE 代码在 `ee/LICENSE` 下有单独许可证。用于商业用途时请确认合规性。

---

## 十一、关键文件索引

### 新建文件（customizations/）

| 文件 | 作用 |
|------|------|
| `customizations/__init__.py` | Django app 包 |
| `customizations/apps.py` | AppConfig，`ready()` 中应用 monkey-patch |
| `customizations/patches/__init__.py` | patches 包 |
| `customizations/patches/unlock_features.py` | P0 核心: 解锁全部 38 个功能 |

### 修改的 PostHog 原始文件

| 文件 | 改动 | 涉及阶段 |
|------|------|---------|
| `posthog/settings/web.py` | INSTALLED_APPS 添加 1 行 | P0 |
| `frontend/src/scenes/userLogic.ts` | `hasAvailableFeature` → `true` | P1 |
| `frontend/src/lib/components/PayGateMini/payGateMiniLogic.tsx` | `gateVariant` → `null` | P1 |
| `frontend/src/lib/components/UpgradeModal/upgradeModalLogic.ts` | `guardAvailableFeature` → 直接执行 | P1 |

### 参考文件（未修改）

| 文件 | 作用 |
|------|------|
| `posthog/constants.py` | AvailableFeature 枚举定义 (38个) |
| `posthog/models/organization.py` | feature 可用性判断（被 monkey-patch） |
| `ee/models/license.py` | License 计划与功能映射 |
| `frontend/src/types.ts` | 前端 AvailableFeature 枚举 (117+个) |
| `posthog/models/alert.py` | 告警数量限制（P0 自动解除） |
| `posthog/permissions.py` | PremiumFeaturePermission（P0 自动通过） |
| `posthog/cloud_utils.py` | `is_cloud()` 部署检测 |
| `ee/billing/billing_manager.py` | Billing 服务集成（自部署不触发） |
| `posthog/tasks/sync_all_organization_available_product_features.py` | Celery 定时同步（调用 patch 方法） |

---

## 十二、变更日志

| 日期 | 阶段 | 变更内容 | 操作人 |
|------|------|---------|--------|
| 2026-03-30 | — | 创建开发计划文档 | — |
| 2026-03-30 | P0 | ✅ 实现 customizations/ 补丁层，monkey-patch 解锁全部 38 个后端功能 | Claude Code |
| 2026-03-30 | P1 | ✅ 修改 userLogic/payGateMiniLogic/upgradeModalLogic，移除前端付费墙 | Claude Code |
| 2026-03-30 | P2 | ✅ 验证确认: P0 自动覆盖所有数量限制，无需额外改动 | Claude Code |
| 2026-03-30 | P4 | ✅ 验证确认: 自部署环境 billing 逻辑自动跳过，无需改动 | Claude Code |
| | | | |
