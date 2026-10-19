import Cocoa
import Carbon

// 合盖保持 — 一个全局菜单栏开关，底层调用 lidawake。
// 左键点一下：开；再点一下：关。右键：菜单（模式、电量、锁屏、日志、授权）。

let fm = FileManager.default
let home = fm.homeDirectoryForCurrentUser
let lidawakePath = home
    .appendingPathComponent("Library/Application Support/lidawake/bin/lidawake").path
let logURL = home.appendingPathComponent("Library/Logs/lid-awake.log")

func logLine(_ s: String) {
    let f = DateFormatter()
    f.dateFormat = "MM-dd HH:mm:ss"
    let line = "\(f.string(from: Date()))  \(s)\n"
    if let d = line.data(using: .utf8) {
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile()
            h.write(d)
            try? h.close()
        } else {
            try? d.write(to: logURL)
        }
    }
}

@discardableResult
func run(_ path: String, _ args: [String], timeout: TimeInterval = 20) -> (Int32, String) {
    guard fm.isExecutableFile(atPath: path) else { return (-1, "not executable: \(path)") }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }

    let deadline = Date().addingTimeInterval(timeout)
    while p.isRunning && Date() < deadline { usleep(50_000) }
    if p.isRunning {
        p.terminate()
        return (-2, "timeout")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

struct LidState {
    var installed = false
    var mode = "unknown"   // auto | forced | paused | unknown
    var holding = false
    var daemon = false
    var power = ""
    var lockOn = true
}

func readState() -> LidState {
    var s = LidState()
    guard fm.isExecutableFile(atPath: lidawakePath) else { return s }
    let (_, out) = run(lidawakePath, ["status"])
    guard !out.isEmpty else { return s }
    s.installed = true
    for raw in out.split(separator: "\n") {
        let line = String(raw)
        if line.hasPrefix("State") {
            s.holding = line.contains("not holding") ? false : line.contains("holding")
        } else if line.hasPrefix("Mode") {
            if line.contains("Let It Sleep") {
                s.mode = "paused"
            } else if line.contains("forced") {
                s.mode = "forced"
            } else if line.contains("Keep Running") {
                s.mode = "auto"
            }
        } else if line.hasPrefix("Power") {
            s.power = line.replacingOccurrences(of: "Power   : ", with: "")
        } else if line.hasPrefix("Daemon") {
            s.daemon = line.contains("running") && !line.contains("not running")
        } else if line.hasPrefix("On shut") {
            s.lockOn = line.contains("lock=on")
        }
    }
    return s
}

func sudoOK() -> Bool {
    let (code, _) = run("/usr/bin/sudo", ["-n", "/usr/bin/pmset", "-g"], timeout: 5)
    return code == 0
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var item: NSStatusItem!
    var timer: Timer?
    var state = LidState()
    var refreshing = false
    var hotKeyRef: EventHotKeyRef?
    var hotKeyHandler: EventHandlerRef?
    var lastToggleAt = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        logLine("app launched")
        // 菜单栏图标可能被刘海挡住，所以同时给 Dock 图标和全局快捷键
        NSApp.setActivationPolicy(.regular)
        buildMainMenu()
        registerHotKey()

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = item.button {
            b.target = self
            b.action = #selector(buttonClicked(_:))
            b.sendAction(on: [.leftMouseUp, .rightMouseUp])
            b.toolTip = "合盖保持"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            if let w = self.item.button?.window {
                logLine("status window frame=\(w.frame) visible=\(w.isVisible) level=\(w.level.rawValue) screen=\(NSScreen.main?.frame ?? .zero)")
            } else {
                logLine("status window is nil; button=\(String(describing: self.item.button))")
            }
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let s = readState()
            DispatchQueue.main.async {
                guard let self else { return }
                self.state = s
                self.refreshing = false
                self.updateIcon()
            }
        }
    }

    var isOn: Bool {
        state.daemon && state.mode != "paused" && state.mode != "unknown"
    }

    func updateIcon() {
        guard let b = item.button else { return }
        let on = isOn
        let name = on ? "cup.and.saucer.fill" : "cup.and.saucer"
        if let img = NSImage(systemSymbolName: name, accessibilityDescription: "合盖保持") {
            img.isTemplate = true
            b.image = img
            b.title = ""
        } else {
            b.image = nil
            b.title = "☕"
        }

        if !state.installed {
            b.contentTintColor = .secondaryLabelColor
            b.toolTip = "合盖保持：未安装（找不到 lidawake）"
        } else if state.holding {
            b.contentTintColor = .systemOrange
            b.toolTip = "合盖保持：开 · 正在保持（合盖继续运行）"
        } else if on {
            b.contentTintColor = .labelColor
            b.toolTip = "合盖保持：开 · 当前未保持（电量低于阈值？）"
        } else if !state.daemon {
            b.contentTintColor = .secondaryLabelColor
            b.toolTip = "合盖保持：未启用（点一下开启）"
        } else {
            b.contentTintColor = .secondaryLabelColor
            b.toolTip = "合盖保持：关（合盖会正常睡眠）"
        }

        NSApp.applicationIconImage = makeDockIcon(on: on)
    }

    func makeDockIcon(on: Bool) -> NSImage {
        let size = NSSize(width: 512, height: 512)
        let image = NSImage(size: size)
        image.lockFocus()
        let inset: CGFloat = 24
        let rect = NSRect(x: inset, y: inset, width: size.width - inset * 2, height: size.height - inset * 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: 120, yRadius: 120)
        (on ? NSColor.systemOrange : NSColor(calibratedWhite: 0.42, alpha: 1)).setFill()
        path.fill()

        let name = on ? "cup.and.saucer.fill" : "cup.and.saucer"
        if let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            let config = NSImage.SymbolConfiguration(pointSize: 300, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            if let sym = base.withSymbolConfiguration(config) {
                let r = NSRect(
                    x: (size.width - sym.size.width) / 2,
                    y: (size.height - sym.size.height) / 2,
                    width: sym.size.width,
                    height: sym.size.height
                )
                sym.draw(in: r)
            }
        }
        image.unlockFocus()
        return image
    }

    func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()

        let toggle = NSMenuItem(title: "切换合盖保持", action: #selector(menuToggle), keyEquivalent: "k")
        toggle.keyEquivalentModifierMask = [.control, .option]
        toggle.target = self
        appMenu.addItem(toggle)

        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "退出合盖保持", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)

        appItem.submenu = appMenu
        NSApp.mainMenu = main
    }

    func registerHotKey() {
        var hotKeyID = EventHotKeyID(signature: OSType(0x4C494457), id: 1) // 'LIDW'
        let mods = UInt32(controlKey | optionKey)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_K), mods, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        logLine("hotkey ⌃⌥K register status=\(status)")

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async {
                (NSApp.delegate as? AppDelegate)?.toggle()
            }
            return noErr
        }, 1, &spec, nil, &hotKeyHandler)
    }

    @objc func menuToggle() {
        toggle()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        toggle()
        return false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let m = NSMenu()
        let toggleItem = NSMenuItem(title: "切换合盖保持", action: #selector(menuToggle), keyEquivalent: "")
        toggleItem.target = self
        m.addItem(toggleItem)
        return m
    }

    @objc func buttonClicked(_ sender: Any?) {
        if let e = NSApp.currentEvent, e.type == .rightMouseUp || e.modifierFlags.contains(.control) {
            showMenu()
        } else {
            toggle()
        }
    }

    func toggle() {
        // 一次点击可能被系统送两次事件（双击 Dock、按键重复），800ms 内只认一次
        let now = Date()
        if now.timeIntervalSince(lastToggleAt) < 0.8 {
            logLine("toggle ignored (debounce)")
            return
        }
        lastToggleAt = now

        guard state.installed else {
            alert("缺少 lidawake 运行时", "没有在\n\(lidawakePath)\n找到 lidawake。\n\n请先在仓库目录运行 ./scripts/install.sh。")
            return
        }
        if isOn {
            setMode("normal")
            return
        }
        if !sudoOK() {
            authorize(then: "auto")
        } else {
            setMode("auto")
        }
    }

    func setMode(_ target: String) {
        // 先把界面状态翻过去，避免连点两下都发同一个方向
        if target == "normal" {
            state.mode = "paused"
            state.daemon = false
            state.holding = false
        } else {
            state.mode = target
            state.daemon = true
        }
        updateIcon()
        logLine("setMode \(target)")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (code, out) = run(lidawakePath, [target], timeout: 30)
            logLine("setMode \(target) exit=\(code) \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
            DispatchQueue.main.async {
                self?.refreshSoon()
                if code != 0 && out.contains("passwordless") {
                    self?.authorize(then: target)
                }
            }
        }
    }

    func refreshSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.refresh()
        }
    }

    // 一次性安装 sudoers 规则 + 启动 lidawake 守护进程
    func authorize(then target: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "需要一次性管理员授权"
        a.informativeText = """
        为了让「合盖也保持运行」，macOS 只允许管理员修改 SleepDisabled。

        点「授权」后系统会弹出密码框，装一条只放行下面三条命令的规则：
          pmset -a disablesleep 1
          pmset -a disablesleep 0
          pmset -g

        不会给你其他 sudo 权限。之后开关都不再需要密码。
        """
        a.addButton(withTitle: "授权")
        a.addButton(withTitle: "取消")
        if a.runModal() != .alertFirstButtonReturn { return }

        guard let script = writeAuthorizer() else {
            alert("授权失败", "无法写入授权脚本。")
            return
        }
        logLine("authorize: prompting")

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let apple = "do shell script \"/bin/bash \(script)\" with administrator privileges"
            let (code, out) = run("/usr/bin/osascript", ["-e", apple], timeout: 180)
            logLine("authorize exit=\(code) \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
            DispatchQueue.main.async {
                guard let self else { return }
                if code != 0 {
                    self.alert("没有授权", "系统没有授予管理员权限，合盖保持仍是关闭的。\n\n\(out)")
                    return
                }
                self.setMode(target)
            }
        }
    }

    func writeAuthorizer() -> String? {
        let user = NSUserName()
        let rules = [
            "# lidawake — passwordless access to exactly three pmset invocations.",
            "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1",
            "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0",
            "\(user) ALL=(root) NOPASSWD: /usr/bin/pmset -g",
        ].joined(separator: "\n")

        let script = """
        #!/bin/bash
        set -euo pipefail
        tmp="$(mktemp)"
        trap 'rm -f "$tmp"' EXIT
        cat > "$tmp" <<'RULES'
        \(rules)
        RULES
        /bin/chmod 0440 "$tmp"
        /usr/sbin/visudo -c -f "$tmp" >/dev/null
        /usr/bin/install -m 0440 -o root -g wheel "$tmp" /etc/sudoers.d/lidawake
        """

        let path = "/tmp/lidawake-authorize.sh"
        do {
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        } catch {
            return nil
        }
        return path
    }

    func showMenu() {
        let m = NSMenu()
        m.autoenablesItems = false

        let statusText: String
        if !state.installed {
            statusText = "未安装 lidawake"
        } else if !state.daemon {
            statusText = "未启用 · 点一下开启"
        } else if state.holding {
            statusText = "正在保持 · \(state.power)"
        } else if state.mode == "paused" {
            statusText = "已关闭（合盖会睡眠）"
        } else {
            statusText = "已开启 · 当前未保持 · \(state.power)"
        }
        let head = NSMenuItem(title: statusText, action: nil, keyEquivalent: "")
        head.isEnabled = false
        m.addItem(head)
        m.addItem(.separator())

        let autoItem = NSMenuItem(title: "合盖保持（自动）", action: #selector(menuAuto), keyEquivalent: "")
        autoItem.target = self
        autoItem.state = state.mode == "auto" ? .on : .off
        m.addItem(autoItem)

        let forcedItem = NSMenuItem(title: "强制保持（忽略电量）", action: #selector(menuForced), keyEquivalent: "")
        forcedItem.target = self
        forcedItem.state = state.mode == "forced" ? .on : .off
        m.addItem(forcedItem)

        let offItem = NSMenuItem(title: "恢复正常睡眠", action: #selector(menuNormal), keyEquivalent: "")
        offItem.target = self
        offItem.state = state.mode == "paused" ? .on : .off
        m.addItem(offItem)

        m.addItem(.separator())

        let lockItem = NSMenuItem(title: "合盖时锁屏", action: #selector(menuLock), keyEquivalent: "")
        lockItem.target = self
        lockItem.state = state.lockOn ? .on : .off
        m.addItem(lockItem)

        let logItem = NSMenuItem(title: "打开日志", action: #selector(menuLog), keyEquivalent: "")
        logItem.target = self
        m.addItem(logItem)

        if !sudoOK() {
            let authItem = NSMenuItem(title: "安装授权…", action: #selector(menuAuthorize), keyEquivalent: "")
            authItem.target = self
            m.addItem(authItem)
        }

        m.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(menuQuit), keyEquivalent: "q")
        quit.target = self
        m.addItem(quit)

        item.menu = m
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc func menuAuto() { setMode("auto") }
    @objc func menuForced() { setMode("forced") }
    @objc func menuNormal() { setMode("normal") }

    @objc func menuLock() {
        let target = state.lockOn ? "off" : "on"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = run(lidawakePath, ["lock", target], timeout: 10)
            DispatchQueue.main.async { self?.refreshSoon() }
        }
    }

    @objc func menuLog() {
        NSWorkspace.shared.open(logURL)
    }

    @objc func menuAuthorize() {
        authorize(then: "auto")
    }

    @objc func menuQuit() {
        NSApp.terminate(nil)
    }

    func alert(_ title: String, _ text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = .informational
        a.addButton(withTitle: "好")
        a.runModal()
    }
}

// CLI 调试：打印将要安装的 sudoers 脚本后退出
if CommandLine.arguments.contains("--print-authorizer") {
    let d = AppDelegate()
    if let path = d.writeAuthorizer(), let text = try? String(contentsOfFile: path, encoding: .utf8) {
        print(text)
        exit(0)
    }
    print("failed to generate")
    exit(1)
}

// CLI 调试：打印 lidawake 状态后退出
if CommandLine.arguments.contains("--dump-status") {
    if !fm.isExecutableFile(atPath: lidawakePath) {
        print("lidawake not found at \(lidawakePath)")
        exit(1)
    }
    let (_, out) = run(lidawakePath, ["status"])
    print(out)
    exit(0)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
