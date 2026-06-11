# ClaudeBar ✳

macOS menu bar app theo dõi liên tục usage limits của Claude (Pro/Max plan) — không cần mở `/usage` trong Claude Code nữa.

**Menu bar:** `✳ 13% · 11%` (session 5h · weekly) — thêm `❗` khi sắp chạm limit.

**Popover khi click:**
- **Limits**: progress bar từng hạng mục (Current session, Weekly · All models, Weekly · Sonnet/Opus, Extra credits) — đổi màu theo mức dùng, kèm giờ reset
- **Burn rate + dự báo**: tốc độ tiêu %/giờ và dự đoán có chạm 100% trước giờ reset không
- **Last 24h**: biểu đồ lịch sử session + weekly
- **Agents running**: các AI coding agent đang chạy trên máy (Claude Code, Codex, Gemini CLI, Aider) kèm thư mục dự án và trạng thái working/idle
- **Today · Claude Code**: token dùng trong ngày (in/out/cache), quy đổi ≈ giá API (tham khảo), biểu đồ chi phí 7 ngày
- **Notifications**: cảnh báo khi vượt 80% / 95%, báo khi session limit reset xong
- **Settings (⚙)**: tuỳ chọn hiển thị menu bar (session %, weekly %, countdown), refresh interval 1m/2m/5m, Launch at Login

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
- Thống kê token đọc từ transcript local của Claude Code (`~/.claude/projects/**/*.jsonl`) — chỉ đọc. Con số $ là quy đổi theo giá niêm yết API để tham khảo, không phải tiền bị trừ (gói Pro/Max trả phí cố định).
- Danh sách agent lấy từ process list của chính user (libproc) — không cần quyền đặc biệt.
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
