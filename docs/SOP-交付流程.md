# 交付流程 SOP（含 GitHub 操作指南）

> **版本**: v1.0 | **维护者**: Issac (PMO)
> **适用项目**: VoiceInput (dennyandwu/VoiceInput)
> **生效日期**: 2026-03-07

---

## 1. 代码提交规范

### 1.1 Commit Message 格式
采用 [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <description>

[optional body]

[optional footer]
```

**Type 类型:**

| Type | 用途 | 示例 |
|------|------|------|
| `feat` | 新功能 | `feat(vad): add silence detection threshold` |
| `fix` | Bug 修复 | `fix(hotkey): crash on modifier key release` |
| `refactor` | 重构 | `refactor(audio): extract AudioEngine class` |
| `docs` | 文档 | `docs: update README installation guide` |
| `build` | 构建/依赖 | `build: update sherpa-onnx to v1.11` |
| `ci` | CI/CD | `ci: add GitHub Actions release workflow` |
| `test` | 测试 | `test: add VAD unit tests` |
| `chore` | 杂务 | `chore: clean build artifacts` |

**Scope 建议**: `audio`, `vad`, `hotkey`, `gui`, `build`, `model`

### 1.2 PR 流程

```
1. 从 dev 创建 feature/xxx 分支
2. 开发完成，本地测试通过
3. 提交 PR → dev
4. Satoshi 自审 or Issac 审（视情况）
5. 通过后 squash merge 到 dev
6. 删除 feature 分支
```

**PR 标题格式**: 同 commit message（`feat(scope): description`）

**PR 描述模板**:
```markdown
## 变更内容
- 

## 测试情况
- [ ] 本地编译通过
- [ ] 功能测试通过
- [ ] 无新增 warning

## 关联
- Phase: P{n}
- Issue: #{n} (如有)
```

---

## 2. GitHub Release 发布流程

### 2.1 发布前检查清单

```markdown
## Release Checklist — v{X.Y.Z}

### 代码准备
- [ ] 所有 feature PR 已合入 dev
- [ ] dev 分支编译通过（swift build -c release）
- [ ] 版本号已更新（Info.plist / build.sh）

### 测试
- [ ] SIT 通过（Ansen 自动化测试）
- [ ] UAT 通过（0xFG 或指定人员在真机测试）
  - [ ] 麦克风录音正常
  - [ ] 热键触发正常
  - [ ] 语音识别准确
  - [ ] MenuBar GUI 正常
  - [ ] 文本粘贴到目标应用正常

### 构建与打包
- [ ] release 构建成功
- [ ] DMG 打包完成
- [ ] DMG 可正常挂载安装
- [ ] 首次启动权限引导正常

### 发布
- [ ] PR: dev → main 已合入
- [ ] git tag 已打
- [ ] GitHub Release 已创建
- [ ] DMG 已上传到 Release Assets
- [ ] Release Notes 已填写
```

### 2.2 手动发布步骤

```bash
# 1. 确保 dev 分支最新且测试通过
git checkout dev
git pull

# 2. 合并到 main
git checkout main
git pull
git merge dev
git push

# 3. 打 tag
git tag -a v0.4.0 -m "v0.4.0: feature description"
git push origin v0.4.0

# 4. 构建 release
./build_app.sh  # 生成 .app bundle
# 制作 DMG (使用 create-dmg 或 hdiutil)
hdiutil create -volname "VoiceInput" -srcfolder build/VoiceInput.app \
  -ov -format UDZO build/VoiceInput-v0.4.0.dmg

# 5. 在 GitHub 创建 Release
# 手动: GitHub → Releases → Draft a new release → 选 tag → 上传 DMG
# 或 CLI:
gh release create v0.4.0 build/VoiceInput-v0.4.0.dmg \
  --title "v0.4.0: feature description" \
  --notes-file RELEASE_NOTES.md
```

### 2.3 Release Notes 格式

```markdown
## VoiceInput v{X.Y.Z}

### 🆕 新功能
- 

### 🐛 修复
- 

### ⚡ 优化
- 

### 📋 系统要求
- macOS 13.0+ (Ventura)
- Apple Silicon (M1/M2/M3/M4)
- ~300MB 磁盘空间

### 📥 安装
1. 下载 VoiceInput-v{X.Y.Z}.dmg
2. 打开 DMG，拖入 /Applications
3. 首次运行右键 → 打开
4. 授予麦克风 + 辅助功能权限
```

---

## 3. CI/CD 自动化（GitHub Actions）

### 3.1 Workflow: 自动构建与发布

```yaml
# .github/workflows/release.yml
name: Build & Release

on:
  push:
    tags:
      - 'v*'

jobs:
  build:
    runs-on: macos-14  # Apple Silicon runner
    steps:
      - uses: actions/checkout@v4

      - name: Setup Swift
        uses: swift-actions/setup-swift@v2

      - name: Download Model
        run: ./download_float32_model.sh

      - name: Build Release
        run: |
          swift build -c release
          ./build_app.sh

      - name: Create DMG
        run: |
          brew install create-dmg
          create-dmg \
            --volname "VoiceInput" \
            --window-pos 200 120 \
            --window-size 600 400 \
            --icon-size 100 \
            --app-drop-link 400 185 \
            "VoiceInput-${{ github.ref_name }}.dmg" \
            "build/VoiceInput.app"

      - name: Create Release
        uses: softprops/action-gh-release@v2
        with:
          files: VoiceInput-${{ github.ref_name }}.dmg
          generate_release_notes: true
          draft: false
          prerelease: ${{ contains(github.ref_name, 'beta') || contains(github.ref_name, 'rc') }}
```

### 3.2 Workflow: PR 自动检查

```yaml
# .github/workflows/ci.yml
name: CI

on:
  pull_request:
    branches: [dev, main]

jobs:
  build-check:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4

      - name: Build Check
        run: swift build -c release 2>&1

      - name: Lint (if applicable)
        run: |
          if command -v swiftlint &>/dev/null; then
            swiftlint lint --strict
          fi
```

### 3.3 使用说明
1. 将上述 yaml 文件放入 repo 的 `.github/workflows/` 目录
2. push tag 时自动触发构建和发布
3. PR 时自动检查编译是否通过
4. **注意**: macOS runner 按分钟计费（GitHub Actions），私有仓库每月 2000 分钟免费

---

## 4. 测试与验收流程

### 4.1 测试分层

```
开发者自测 → SIT（自动化） → UAT（人工） → Release
```

| 阶段 | 执行者 | 内容 | 通过标准 |
|------|--------|------|----------|
| **开发自测** | Satoshi | 编译通过、基本功能 | 无 crash、核心功能可用 |
| **SIT** | Ansen (自动化) | 单元测试、集成测试 | 全部 pass，覆盖率 > 60% |
| **UAT** | 0xFG / 指定人 | 真机全功能测试 | 所有用户场景通过 |

### 4.2 SIT 自动化（Ansen 负责）
- 测试框架: XCTest (Swift 原生)
- 覆盖范围: 音频处理、VAD、模型加载、热键
- 触发: PR 合入时 / 手动触发
- 结果: 发送到运维频道

### 4.3 UAT 检查项（VoiceInput 专用）
```markdown
## UAT — VoiceInput v{X.Y.Z}

### 基础功能
- [ ] 安装顺畅（DMG → Applications）
- [ ] 首次启动权限引导正常
- [ ] MenuBar 图标显示正常

### 核心功能
- [ ] 按住热键录音，松开识别
- [ ] 中文识别准确率 > 90%
- [ ] 英文识别准确率 > 85%
- [ ] 文本正确粘贴到当前应用
- [ ] 多应用切换后仍正常工作

### 稳定性
- [ ] 连续使用 30 分钟无 crash
- [ ] 内存占用 < 500MB
- [ ] CPU 空闲时 < 5%

### 测试环境
- 设备: ___
- macOS 版本: ___
- 测试人: ___
- 日期: ___
```

---

## 5. 版本发布通知

### 5.1 内部通知
发布完成后 Issac 在以下渠道通知：
- **Discord #岛上快报** (993273127201165313): 版本发布公告
- **Discord #开发中心** (993272794034999397): 技术变更详情
- **A2A**: 通知 Ansen 更新部署文档

### 5.2 通知模板
```
🚀 VoiceInput v{X.Y.Z} 已发布

🆕 新功能:
- xxx

🐛 修复:
- xxx

📥 下载: https://github.com/dennyandwu/VoiceInput/releases/tag/v{X.Y.Z}
```

---

## 6. 紧急修复 (Hotfix) 流程

### 6.1 触发条件
- 线上版本存在 crash / 数据丢失 / 功能完全不可用

### 6.2 流程
```
1. 从 main 拉 hotfix/vX.Y.Z 分支
2. 修复问题，最小化变更
3. 本地验证通过
4. PR → main（跳过 dev，紧急通道）
5. Issac 快速 review
6. 合入 main，打 patch tag (vX.Y.Z+1)
7. 自动构建发布
8. 同步合并 hotfix → dev
9. 通知所有相关人员
```

### 6.3 审批
- hotfix PR 仅需 **Issac 或 0xFG** 一人审批即可合入
- 事后补充完整测试

---

## 7. 跨团队协作边界

### 7.1 职责矩阵 (RACI)

| 活动 | Satoshi (CTO) | Ansen (运维) | Issac (PMO) | 0xFG (老板) |
|------|:---:|:---:|:---:|:---:|
| 架构设计 | **R** | C | I | A |
| 编码开发 | **R** | - | I | - |
| Code Review | R | - | **R** | - |
| SIT 测试 | C | **R** | I | - |
| UAT 测试 | C | C | **R** | A |
| CI/CD 配置 | C | **R** | I | - |
| Release 发布 | R | **R** | A | I |
| 进度跟踪 | I | I | **R** | I |
| 风险升级 | R | R | **R** | A |

> R=执行 A=审批 C=咨询 I=知会

### 7.2 协作通道
- **日常沟通**: Discord 各频道
- **任务派发**: A2A (Agent-to-Agent)
- **文档协作**: Obsidian → GitHub 同步
- **代码协作**: GitHub PR

### 7.3 审批链
```
代码变更:   Satoshi 提交 → Issac review → 合入
发版决策:   Satoshi 确认代码 → Ansen 确认测试 → Issac 审批发布
紧急修复:   任何人提交 → Issac/0xFG 审批 → 立即发布
架构变更:   Satoshi 提案 → 0xFG 决策
```
