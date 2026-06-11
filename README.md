# ClaudeBar ✳

macOS menu bar app theo dõi liên tục usage limits của Claude (Pro/Max plan) — không cần mở `/usage` trong Claude Code nữa.

**Menu bar:** `✳ 13% · 11%` (session 5h · weekly) — thêm `❗` khi sắp chạm limit.

**Popover khi click:**
- Progress bar từng hạng mục: Current session, Weekly · All models, Weekly · Sonnet/Opus, Extra usage credits — đổi màu xanh/vàng/đỏ theo mức dùng
- Giờ reset của từng hạng mục
- **Burn rate + dự báo**: tốc độ tiêu %/giờ và dự đoán có chạm 100% trước giờ reset không
- **Sparkline 24h**: biểu đồ lịch sử session + weekly
- **Notifications**: cảnh báo khi vượt 80% / 95%, và báo khi session limit reset xong
- Tuỳ chọn hiển thị menu bar (session %, weekly %, countdown tới reset)
- Refresh interval: 15s / 30s / 60s / 5m (mặc định 30s)
- Launch at Login

## Cài đặt

1. Tải `ClaudeBar.dmg` từ [Releases](../../releases), mở và kéo **ClaudeBar** vào **Applications**.
2. Vì app chưa notarize (không có Apple Developer ID), lần đầu mở macOS sẽ chặn:
   - Mở **System Settings → Privacy & Security**, kéo xuống và bấm **Open Anyway**.
   - Hoặc chạy: `xattr -d com.apple.quarantine /Applications/ClaudeBar.app`
3. Khi macOS hỏi quyền truy cập Keychain item của Claude Code → bấm **Always Allow**.
4. Khi app xin quyền Notifications → **Allow** (để nhận cảnh báo ngưỡng).

**Yêu cầu:** macOS 14+, đã đăng nhập [Claude Code](https://claude.com/claude-code) trên máy (app dùng phiên đăng nhập đó để đọc usage).

## Cách hoạt động & bảo mật

- App đọc OAuth token của Claude Code từ macOS Keychain (item `Claude Code-credentials`) — **chỉ đọc**, không sửa, không tự refresh token, không gửi đi đâu ngoài `api.anthropic.com`.
- Gọi `GET https://api.anthropic.com/api/oauth/usage` theo chu kỳ — cùng endpoint mà lệnh `/usage` của Claude Code dùng.
- Nếu token hết hạn (lâu không dùng Claude Code), app hiện cảnh báo "mở Claude Code để làm mới" thay vì hiện số sai.
- Lịch sử usage lưu local tại `~/Library/Application Support/ClaudeBar/history.json` (48h). Log tại `~/Library/Logs/ClaudeBar.log`.
- Không thu thập, không gửi telemetry. Toàn bộ source code trong repo này.

## Build từ source

```bash
git clone <repo-url> && cd ClaudeBar
./scripts/build_dmg.sh 1.1.0   # → dist/ClaudeBar.dmg (universal: Apple Silicon + Intel)
```

Yêu cầu Xcode 16+ / Swift 6.

## Cấu trúc source

- `Sources/ClaudeBar/ClaudeBarApp.swift` — entry point, MenuBarExtra
- `Sources/ClaudeBar/UsageModel.swift` — fetch API, burn rate, dự báo, cảnh báo ngưỡng
- `Sources/ClaudeBar/KeychainTokenProvider.swift` — đọc token từ Keychain
- `Sources/ClaudeBar/HistoryStore.swift` — lưu lịch sử usage cho sparkline
- `Sources/ClaudeBar/Notifier.swift` — macOS notifications
- `Sources/ClaudeBar/PopoverView.swift` — UI popover (SwiftUI + Charts)
- `scripts/build_dmg.sh` — build universal binary → .app → codesign → .dmg

## License

MIT
