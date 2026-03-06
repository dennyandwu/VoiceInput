# 卸载 VoiceInput

## 标准卸载步骤

1. **退出 VoiceInput**
   - 点击菜单栏的 VoiceInput 图标
   - 右键选择「退出」

2. **删除应用**
   ```bash
   # 从 /Applications 删除
   rm -rf /Applications/VoiceInput.app
   
   # 或从 ~/Applications 删除
   rm -rf ~/Applications/VoiceInput.app
   ```

3. **删除用户设置**
   ```bash
   defaults delete com.urdao.voiceinput
   ```

4. **删除 LaunchAgent（如果启用了开机启动）**
   ```bash
   # 先停止服务
   launchctl unload ~/Library/LaunchAgents/com.urdao.VoiceInput.plist 2>/dev/null
   
   # 删除 plist 文件
   rm -f ~/Library/LaunchAgents/com.urdao.VoiceInput.plist
   ```

## 确认已完全卸载

```bash
# 验证无残留进程
pgrep -f VoiceInput && echo "还有进程在运行！" || echo "✅ 无残留进程"

# 验证无残留设置
defaults read com.urdao.voiceinput 2>/dev/null && echo "还有设置残留！" || echo "✅ 无残留设置"

# 验证无残留 LaunchAgent
ls ~/Library/LaunchAgents/com.urdao.VoiceInput.plist 2>/dev/null && echo "还有 LaunchAgent！" || echo "✅ 无残留 LaunchAgent"
```

## 说明

VoiceInput 是一个纯本地应用，不会：
- 向任何服务器发送数据
- 写入系统级别的配置（除 LaunchAgent plist 外）
- 修改系统文件

删除 .app 文件后，仅剩 UserDefaults 数据（约 1KB）和可选的 LaunchAgent plist。
