import Cocoa
import SwiftUI
import SQLite3
import Combine

// MARK: - 诊断日志（FUNDBAR_DEBUG=1 时开启）

enum DebugLog {
    static var enabled: Bool { ProcessInfo.processInfo.environment["FUNDBAR_DEBUG"] == "1" || FileManager.default.fileExists(atPath: "/tmp/fundbar-debug") }
    static let url = URL(fileURLWithPath: "/tmp/fundbar.log")
    static func write(_ text: String) {
        guard enabled else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write("[\(stamp)] \(text)\n".data(using: .utf8)!)
            try? h.close()
        } else {
            try? "[\(stamp)] \(text)\n".write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - 数据模型

struct Fund: Identifiable {
    let code: String
    let name: String
    let money: Double        // 持有金额
    let sector: String       // 关联板块
    let sectorRatio: Double  // 板块当日涨幅（%）
    let monthIncome: Double  // 本月收益（元）

    var id: String { code }

    /// 当日收益（元）= 持有金额 × 板块涨幅
    var dailyAmount: Double { money * sectorRatio / 100 }

    /// 本月收益率（%）= 本月收益 / 月初市值
    var monthRatio: Double {
        let base = money - monthIncome
        return base != 0 ? monthIncome / base * 100 : 0
    }

    var displayName: String {
        name.count > 12 ? String(name.prefix(12)) + "…" : name
    }
}

struct Snapshot {
    let funds: [Fund]
    let dbMTime: Date?
    let loadedAt: Date

    var assets: Double { funds.reduce(0) { $0 + $1.money } }
    var dailyAmount: Double { funds.reduce(0) { $0 + $1.dailyAmount } }
    var monthIncome: Double { funds.reduce(0) { $0 + $1.monthIncome } }
    var dailyRate: Double { assets != 0 ? dailyAmount / assets * 100 : 0 }
}

// MARK: - 读取养基宝本地库

enum DBReader {
    static func locateDB() -> URL? {
        let fm = FileManager.default
        let base = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Containers", isDirectory: true)
        guard let subs = try? fm.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var best: (url: URL, mtime: Date)?
        for sub in subs {
            let p = sub.appendingPathComponent("Data/Documents/YJB.sqlite")
            guard let attrs = try? fm.attributesOfItem(atPath: p.path),
                  let m = attrs[.modificationDate] as? Date else { continue }
            if best == nil || m > best!.mtime { best = (p, m) }
        }
        return best?.url
    }

    static func load() -> Snapshot? {
        guard let url = locateDB() else { return nil }

        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            if db != nil { sqlite3_close(db) }
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 3000)

        var funds: [Fund] = []
        let sql = """
        SELECT code, short_name, money, month_income, sector_info
        FROM hold_fund
        ORDER BY sort_index ASC;
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let code = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
                let name = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? code
                let money = sqlite3_column_double(stmt, 2)
                let monthIncome = sqlite3_column_double(stmt, 3)

                var sector = ""
                var ratio = 0.0
                if let blob = sqlite3_column_blob(stmt, 4) {
                    let len = Int(sqlite3_column_bytes(stmt, 4))
                    let data = Data(bytes: blob, count: len)
                    if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        sector = obj["name"] as? String ?? ""
                        ratio = (obj["ratio"] as? NSNumber)?.doubleValue ?? 0
                    }
                }

                funds.append(Fund(code: code, name: name, money: money,
                                  sector: sector, sectorRatio: ratio, monthIncome: monthIncome))
            }
        }
        sqlite3_finalize(stmt)

        guard !funds.isEmpty else { return nil }
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        return Snapshot(funds: funds, dbMTime: mtime, loadedAt: Date())
    }
}

// MARK: - 格式化

private let moneyFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.minimumFractionDigits = 2
    f.maximumFractionDigits = 2
    f.usesGroupingSeparator = true
    return f
}()

func moneyText(_ v: Double) -> String {
    moneyFormatter.string(from: NSNumber(value: abs(v))) ?? "0.00"
}

func signedMoney(_ v: Double) -> String {
    let body = moneyText(v)
    if v > 0 { return "+" + body }
    if v < 0 { return "-" + body }
    return body
}

func pctText(_ v: Double) -> String {
    String(format: "%+.2f%%", v)
}

func pnlColor(_ v: Double) -> Color {
    if v > 0 { return Color(red: 0.93, green: 0.29, blue: 0.24) }
    if v < 0 { return Color(red: 0.13, green: 0.68, blue: 0.40) }
    return .secondary
}

func pnlNSColor(_ v: Double) -> NSColor {
    if v > 0 { return NSColor(calibratedRed: 0.93, green: 0.29, blue: 0.24, alpha: 1) }
    if v < 0 { return NSColor(calibratedRed: 0.13, green: 0.68, blue: 0.40, alpha: 1) }
    return .secondaryLabelColor
}

extension NSRect {
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}

// MARK: - 实时行情（板块指数）

enum QuoteService {
    /// 已知板块（内置，命中就不用联网查）
    static let secidMap: [String: String] = [
        "上证科创芯片": "1.000685",
        "中证机器人": "2.H30590",
        "中证人工智能": "2.930713",
        "纳斯达克100": "100.NDX"
    ]

    private static let cacheKey = "sectorSecidCache"
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 6
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    private static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/120 Safari/537.36"

    /// 板块名 → secid，先查内置与缓存
    static func knownSecid(forSector name: String) -> String? {
        if let exact = secidMap[name] { return exact }
        if let cached = cache()[name] { return cached }
        if name.contains("科创芯片") { return secidMap["上证科创芯片"] }
        if name.contains("机器人") { return secidMap["中证机器人"] }
        if name.contains("人工智能") { return secidMap["中证人工智能"] }
        if name.contains("纳斯达克") { return secidMap["纳斯达克100"] }
        return nil
    }

    private static func cache() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: cacheKey) as? [String: String] ?? [:]
    }

    private static func storeCache(_ map: [String: String]) {
        var merged = cache()
        merged.merge(map) { _, new in new }
        UserDefaults.standard.set(merged, forKey: cacheKey)
    }

    /// 联网按名称解析成指数 secid（东方财富搜索接口）
    static func resolveSecid(forSector name: String) -> String? {
        var comps = URLComponents(string: "https://searchapi.eastmoney.com/api/suggest/get")!
        comps.queryItems = [
            URLQueryItem(name: "input", value: name),
            URLQueryItem(name: "type", value: "14"),
            URLQueryItem(name: "token", value: "D43BF722C8E33BDC906FB84D85E326E8"),
            URLQueryItem(name: "count", value: "10")
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("https://quote.eastmoney.com/", forHTTPHeaderField: "Referer")

        let sem = DispatchSemaphore(value: 0)
        var found: String?

        session.dataTask(with: req) { data, _, _ in
            defer { sem.signal() }
            guard let data,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let table = root["QuotationCodeTable"] as? [String: Any],
                  let rows = table["Data"] as? [[String: Any]] else { return }

            for row in rows {
                guard (row["SecurityTypeName"] as? String) == "指数" else { continue }
                guard let code = row["Code"] as? String else { continue }
                let mkt: String
                if let m = row["MktNum"] as? String { mkt = m }
                else if let m = row["MktNum"] as? NSNumber { mkt = m.stringValue }
                else { continue }
                found = "\(mkt).\(code)"
                return
            }
        }.resume()

        _ = sem.wait(timeout: .now() + 7)
        if let found { storeCache([name: found]) }
        return found
    }

    /// 批量取涨跌幅：[secid: 当日涨跌幅%]
    static func fetch(secids: [String], completion: @escaping ([String: Double]?) -> Void) {
        guard !secids.isEmpty else { completion(nil); return }

        var bareToSecid: [String: String] = [:]
        for sid in secids {
            let parts = sid.split(separator: ".", maxSplits: 1)
            if parts.count == 2 { bareToSecid[String(parts[1])] = sid }
        }

        var comps = URLComponents(string: "https://push2.eastmoney.com/api/qt/ulist.np/get")!
        comps.queryItems = [
            URLQueryItem(name: "secids", value: secids.joined(separator: ",")),
            URLQueryItem(name: "fields", value: "f12,f14,f2,f3")
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        session.dataTask(with: req) { data, _, _ in
            guard let data,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let d = root["data"] as? [String: Any],
                  let diff = d["diff"] as? [[String: Any]] else {
                completion(nil)
                return
            }
            var out: [String: Double] = [:]
            for item in diff {
                guard let bare = item["f12"] as? String,
                      let sid = bareToSecid[bare] else { continue }
                let pct = (item["f3"] as? NSNumber)?.doubleValue ?? 0
                out[sid] = pct / 100
            }
            completion(out)
        }.resume()
    }

    /// 把板块名解析成 secid（未知的联网查一次并缓存）
    static func secidTable(forSectors names: [String]) -> [String: String] {
        var table: [String: String] = [:]
        for name in Set(names) where !name.isEmpty {
            if let sid = knownSecid(forSector: name) {
                table[name] = sid
            } else if let sid = resolveSecid(forSector: name) {
                table[name] = sid
            }
        }
        return table
    }
}

// MARK: - 模型

final class DashboardModel: ObservableObject {
    @Published var snapshot: Snapshot?
    @Published var hideAmounts: Bool { didSet { defaults.set(hideAmounts, forKey: "hideAmounts") } }
    @Published var pinned: Bool { didSet { defaults.set(pinned, forKey: "pinned") } }
    @Published var showAssets: Bool { didSet { defaults.set(showAssets, forKey: "showAssets") } }
    @Published var showSector: Bool { didSet { defaults.set(showSector, forKey: "showSector") } }
    @Published var showMonth: Bool { didSet { defaults.set(showMonth, forKey: "showMonth") } }
    @Published var opacity: Double { didSet { defaults.set(opacity, forKey: "opacity") } }
    @Published var lastError: String?
    @Published var liveRatios: [String: Double] = [:]
    @Published var quoteTime: Date?
    @Published var quoteOK = false

    var onPinChanged: ((Bool) -> Void)?
    var onClose: (() -> Void)?

    private let defaults = UserDefaults.standard

    init() {
        let d = UserDefaults.standard
        hideAmounts = d.bool(forKey: "hideAmounts")
        pinned = d.bool(forKey: "pinned")
        showAssets = d.object(forKey: "showAssets") as? Bool ?? true
        showSector = d.object(forKey: "showSector") as? Bool ?? true
        showMonth = d.object(forKey: "showMonth") as? Bool ?? true
        let storedOpacity = d.object(forKey: "opacity") as? Double
        opacity = storedOpacity ?? 0.92
    }

    func refresh() {
        if let s = DBReader.load() {
            snapshot = s
            lastError = nil
        } else if snapshot == nil {
            lastError = "未读到养基宝数据，请先打开养基宝"
        }
        fetchQuotes()
    }

    // MARK: 行情

    private func fetchQuotes() {
        guard let funds = snapshot?.funds, !funds.isEmpty else { return }
        let sectors = funds.map { $0.sector }.filter { !$0.isEmpty }

        DispatchQueue.global(qos: .utility).async {
            let table = QuoteService.secidTable(forSectors: sectors)
            guard !table.isEmpty else {
                DispatchQueue.main.async { self.quoteOK = false }
                return
            }

            QuoteService.fetch(secids: Array(Set(table.values))) { result in
                DispatchQueue.main.async {
                    guard let result else {
                        self.quoteOK = false
                        return
                    }
                    var mapped: [String: Double] = [:]
                    for fund in funds {
                        guard let sid = table[fund.sector], let pct = result[sid] else { continue }
                        mapped[fund.code] = pct
                    }
                    guard !mapped.isEmpty else { self.quoteOK = false; return }
                    self.liveRatios = mapped
                    self.quoteTime = Date()
                    self.quoteOK = true
                }
            }
        }
    }

    // MARK: 计算

    /// 优先用实时指数涨幅，取不到时回落到养基宝库里的值
    func effectiveRatio(_ f: Fund) -> Double {
        liveRatios[f.code] ?? f.sectorRatio
    }

    func dailyAmount(_ f: Fund) -> Double {
        f.money * effectiveRatio(f) / 100
    }

    var totalAssets: Double { snapshot?.assets ?? 0 }
    var totalDaily: Double { (snapshot?.funds ?? []).reduce(0) { $0 + dailyAmount($1) } }
    var totalMonth: Double { snapshot?.monthIncome ?? 0 }
    var totalRate: Double { totalAssets != 0 ? totalDaily / totalAssets * 100 : 0 }

    func toggleHide() { hideAmounts.toggle() }

    func togglePin() {
        pinned.toggle()
        onPinChanged?(pinned)
    }
}

// MARK: - 半透明背景

struct VisualEffectBackground: NSViewRepresentable {
    var opacity: Double = 1

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        v.alphaValue = opacity
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.alphaValue = opacity
    }
}

// MARK: - 界面

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    @State private var showSettings = false

    init(model: DashboardModel, settingsOpen: Bool = false) {
        self.model = model
        _showSettings = State(initialValue: settingsOpen)
    }

    private var snap: Snapshot? { model.snapshot }

    private let dailyWidth: CGFloat = 86
    private let sectorWidth: CGFloat = 104
    private let monthWidth: CGFloat = 104
    private let minNameWidth: CGFloat = 154
    private let hPadding: CGFloat = 32

    /// 除基金名以外的固定占用
    private var fixedWidth: CGFloat {
        var w = hPadding + dailyWidth
        if model.showSector { w += sectorWidth }
        if model.showMonth { w += monthWidth }
        return w
    }

    private var cardWidth: CGFloat {
        max(fixedWidth + minNameWidth, 300)
    }

    /// 基金名列吃掉剩余宽度
    private var nameWidth: CGFloat {
        cardWidth - fixedWidth
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if showSettings {
                settingsBar.padding(.top, 12)
            }
            divider
            columnHeader
            rows
            divider
            footer
        }
        .padding(16)
        .frame(width: cardWidth)
        .background(VisualEffectBackground(opacity: model.opacity))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1).padding(.vertical, 10)
    }

    // MARK: 顶部

    // MARK: 顶部

    /// 宽面板一行；窄面板按需两行，且「账户资产」跟随开关
    @ViewBuilder
    private var header: some View {
        if cardWidth >= 400 {
            HStack(alignment: .center, spacing: 0) {
                if model.showAssets {
                    assetsBlock
                    Spacer(minLength: 10)
                } else {
                    Spacer(minLength: 0)
                }
                Text("今日盈亏")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 7)
                    .fixedSize()
                dailyTexts
                toolButtons.padding(.leading, 14)
            }
        } else if model.showAssets {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    assetsBlock
                    Spacer(minLength: 8)
                    toolButtons
                }
                HStack(spacing: 6) {
                    Text("今日盈亏")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    dailyTexts
                    Spacer(minLength: 0)
                }
            }
        } else {
            // 窄面板且隐藏资产：一行放「今日盈亏 + 按钮」（标签省略以免超宽）
            HStack(spacing: 0) {
                dailyTexts
                Spacer(minLength: 8)
                toolButtons
            }
        }
    }

    private var assetsBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("账户资产")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Text(model.hideAmounts ? "••••••" : moneyText(model.totalAssets))
                .font(.system(size: 20, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .fixedSize()
    }

    private var dailyTexts: some View {
        HStack(spacing: 5) {
            Text(model.hideAmounts ? "••••" : signedMoney(model.totalDaily))
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(pnlColor(model.totalDaily))
                .fixedSize()
            Text(pctText(model.totalRate))
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(pnlColor(model.totalDaily))
                .fixedSize()
        }
    }

    private var toolButtons: some View {
        HStack(spacing: 8) {
            iconButton(model.hideAmounts ? "eye.slash" : "eye", help: "显示/隐藏金额") {
                model.toggleHide()
            }
            iconButton(model.pinned ? "pin.fill" : "pin", help: "固定常驻") {
                model.togglePin()
            }
            iconButton("slider.horizontal.3", help: "显示设置", active: showSettings) {
                showSettings.toggle()
            }
            iconButton("xmark", help: "关闭") { model.onClose?() }
        }
    }

    // MARK: 设置

    private var settingsBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                chip("账户资产", isOn: $model.showAssets)
                chip("关联板块", isOn: $model.showSector)
                chip("本月收益", isOn: $model.showMonth)
            }
            HStack(spacing: 8) {
                Text("背景")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Slider(value: $model.opacity, in: 0.25...1.0)
                    .frame(width: 110)
                    .controlSize(.mini)
                Text("\(Int(model.opacity * 100))%")
                    .font(.system(size: 10, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 30, alignment: .trailing)
            }
        }
    }

    private func chip(_ title: String, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(title)
                .font(.system(size: 10.5, weight: .medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    isOn.wrappedValue
                        ? Color.accentColor.opacity(0.30)
                        : Color.white.opacity(0.07),
                    in: Capsule()
                )
                .foregroundStyle(isOn.wrappedValue ? Color.white : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: 表头与行

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Text("持有基金").frame(width: nameWidth, alignment: .leading)
            Text("当日收益").frame(width: dailyWidth, alignment: .trailing)
            if model.showSector {
                Text("关联板块").frame(width: sectorWidth, alignment: .trailing)
            }
            if model.showMonth {
                Text("本月收益").frame(width: monthWidth, alignment: .trailing)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.bottom, 6)
    }

    private var rows: some View {
        VStack(spacing: 0) {
            if let funds = snap?.funds, !funds.isEmpty {
                ForEach(funds) { f in
                    HStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.displayName)
                                .font(.system(size: 12.5, weight: .medium))
                                .lineLimit(1)
                            Text(f.code)
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(width: nameWidth, alignment: .leading)

                        VStack(alignment: .trailing, spacing: 2) {
                            Text(model.hideAmounts ? "••••" : signedMoney(model.dailyAmount(f)))
                                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                                .monospacedDigit()
                            Text(pctText(model.effectiveRatio(f)))
                                .font(.system(size: 10, design: .rounded))
                                .monospacedDigit()
                                .opacity(0.85)
                        }
                        .foregroundStyle(pnlColor(model.effectiveRatio(f)))
                        .frame(width: dailyWidth, alignment: .trailing)

                        if model.showSector {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(f.sector)
                                    .font(.system(size: 11.5))
                                    .lineLimit(1)
                                Text(pctText(model.effectiveRatio(f)))
                                    .font(.system(size: 10, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(pnlColor(model.effectiveRatio(f)))
                            }
                            .frame(width: sectorWidth, alignment: .trailing)
                        }

                        if model.showMonth {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(model.hideAmounts ? "••••" : signedMoney(f.monthIncome))
                                    .font(.system(size: 12.5, weight: .medium, design: .rounded))
                                    .monospacedDigit()
                                Text(pctText(f.monthRatio))
                                    .font(.system(size: 10, design: .rounded))
                                    .monospacedDigit()
                                    .opacity(0.85)
                            }
                            .foregroundStyle(pnlColor(f.monthIncome))
                            .frame(width: monthWidth, alignment: .trailing)
                        }
                    }
                    .padding(.vertical, 6)
                }
            } else {
                Text(model.lastError ?? "正在读取…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 18)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if model.showMonth {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.hideAmounts ? "••••" : signedMoney(model.totalMonth))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(pnlColor(model.totalMonth))
                    Text("本月合计")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .fixedSize()
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    if model.quoteOK {
                        Circle().fill(Color(red: 0.20, green: 0.78, blue: 0.45)).frame(width: 5, height: 5)
                    }
                    Text(updatedText)
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Text(sourceNote)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .fixedSize()

            iconButton("arrow.clockwise", help: "刷新") { model.refresh() }
        }
    }

    private var updatedText: String {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss"
        if model.quoteOK, let t = model.quoteTime {
            return "实时 " + df.string(from: t)
        }
        guard let t = snap?.dbMTime else { return "数据时间未知" }
        let df2 = DateFormatter()
        df2.dateFormat = "MM-dd HH:mm"
        return "数据 " + df2.string(from: t)
    }

    private var sourceNote: String {
        model.quoteOK ? "实时指数 × 持仓" : "当日 = 持仓 × 板块涨幅"
    }

    private func iconButton(_ symbol: String, help: String,
                            active: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 24, height: 24)
                .background(active ? Color.accentColor.opacity(0.30) : Color.white.opacity(0.08), in: Circle())
                .foregroundStyle(active ? Color.white : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - 悬浮面板

final class PanelController {
    private(set) var panel: NSPanel!
    private let model: DashboardModel
    private let hosting: NSHostingView<DashboardView>
    private var canceller: AnyCancellable?
    private var layoutTimer: Timer?

    init(model: DashboardModel) {
        self.model = model
        hosting = NSHostingView(rootView: DashboardView(model: model))
        hosting.frame = NSRect(origin: .zero, size: hosting.fittingSize)

        panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none

        applyPin(model.pinned)
        model.onPinChanged = { [weak self] pinned in self?.applyPin(pinned) }
        model.onClose = { [weak self] in self?.hide() }

        // 数据/开关变化后，延迟重排（SwiftUI 排版发生在下一个事务）
        canceller = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { self?.resizeToFit() }
            }

        // 兜底：面板可见时每 0.4s 校准一次尺寸与位置
        layoutTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.resizeToFit()
        }
        RunLoop.main.add(layoutTimer!, forMode: .common)
    }

    /// 让窗口尺寸跟随内容，并保证始终完整落在屏幕内
    func resizeToFit() {
        let size = hosting.fittingSize
        if size.width > 1, size.height > 1 {
            let old = panel.frame
            if abs(old.width - size.width) > 0.5 || abs(old.height - size.height) > 0.5 {
                panel.setContentSize(size)
                var rect = panel.frame
                rect.origin.y = old.maxY - rect.height      // 顶边固定
                rect.origin.x = old.midX - rect.width / 2   // 水平保持中心
                panel.setFrame(rect, display: true)
                DebugLog.write("resize \(Int(old.width))x\(Int(old.height)) -> \(Int(size.width))x\(Int(size.height))")
            }
        }
        clampToScreen()
    }

    /// 选出与窗口重叠最多的屏幕
    private var currentScreen: NSScreen? {
        let f = panel.frame
        let screens = NSScreen.screens
        let best = screens.max { a, b in
            a.frame.intersection(f).area < b.frame.intersection(f).area
        }
        if let best, best.frame.intersection(f).area > 0 { return best }
        return panel.screen ?? NSScreen.main ?? screens.first
    }

    /// 完整夹进屏幕可见区域
    private func clampToScreen(preferring preferred: NSScreen? = nil) {
        let screen = preferred ?? currentScreen
        guard let visible = screen?.visibleFrame else { return }
        let f = panel.frame
        guard f.width > 1, f.height > 1 else { return }
        let m: CGFloat = 8
        var r = f
        r.origin.x = min(max(r.origin.x, visible.minX + m), max(visible.minX + m, visible.maxX - r.width - m))
        r.origin.y = min(max(r.origin.y, visible.minY + m), max(visible.minY + m, visible.maxY - r.height - m))
        if r.origin != f.origin {
            panel.setFrameOrigin(r.origin)
            DebugLog.write("clamp \(f.origin) -> \(r.origin)")
        }
    }

    private func applyPin(_ pinned: Bool) {
        if pinned {
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        } else {
            panel.level = .normal
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        }
    }

    /// 状态栏图标的屏幕坐标（不是整条菜单栏）
    private func anchorRect(for button: NSStatusBarButton?) -> NSRect? {
        guard let button, let win = button.window else { return nil }
        let inWindow = button.convert(button.bounds, to: nil)
        return win.convertToScreen(inWindow)
    }

    // MARK: 位置记忆

    private let originKey = "panelOriginX"
    private let originYKey = "panelOriginY"

    private func savedOrigin() -> NSPoint? {
        let d = UserDefaults.standard
        guard d.object(forKey: originKey) != nil, d.object(forKey: originYKey) != nil else { return nil }
        return NSPoint(x: d.double(forKey: originKey), y: d.double(forKey: originYKey))
    }

    private func saveOrigin() {
        let o = panel.frame.origin
        UserDefaults.standard.set(o.x, forKey: originKey)
        UserDefaults.standard.set(o.y, forKey: originYKey)
    }

    /// 默认位置：主屏右上角、菜单栏下方
    private var defaultOrigin: NSPoint {
        let vis = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: vis.maxX - panel.frame.width - 16,
                       y: vis.maxY - panel.frame.height - 12)
    }

    /// 鼠标所在的屏幕——用户点菜单栏时，视线就在这块屏上
    private var mouseScreen: NSScreen? {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(p) }
    }

    func show(relativeTo button: NSStatusBarButton?) {
        model.refresh()
        resizeToFit()

        let target = mouseScreen ?? NSScreen.main
        let visible = target?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        // 记住的位置只在这块屏幕上才复用，否则回到右上角，避免"弹到另一块屏"
        if let saved = savedOrigin(),
           let savedScreen = NSScreen.screens.first(where: { $0.frame.contains(saved) }),
           savedScreen == target {
            panel.setFrameOrigin(saved)
        } else {
            panel.setFrameOrigin(NSPoint(x: visible.maxX - panel.frame.width - 16,
                                         y: visible.maxY - panel.frame.height - 12))
        }

        // 任何空间都显示，避免落在非活动空间里"看不见"
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        clampToScreen(preferring: target)
        DebugLog.write("show target=\(target?.localizedName ?? "?") origin=\(panel.frame.origin)")

        panel.orderFrontRegardless()
        panel.makeKey()
        resizeToFit()
    }

    /// 点击时：当前屏可见才收起，否则重新定位弹出（避免"点了没反应"）
    func toggle(relativeTo button: NSStatusBarButton?) {
        guard panel.isVisible else {
            show(relativeTo: button)
            return
        }
        if let target = mouseScreen, target.frame.intersects(panel.frame) {
            hide()
        } else {
            show(relativeTo: button)
        }
    }

    /// 这个坐标是否落在某块屏幕的可见区域内
    private func isReachable(_ p: NSPoint) -> Bool {
        NSScreen.screens.contains { $0.visibleFrame.insetBy(dx: 2, dy: 2).contains(p) }
    }

    func hide() {
        saveOrigin()
        panel.orderOut(nil)
    }

}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var model: DashboardModel!
    private var panelController: PanelController!
    private var timer: Timer?

    private let appBundleID = "com.xiaoduotou.yjb"
    private let launchAgentLabel = "com.local.fundbar.pnl"

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = DashboardModel()
        panelController = PanelController(model: model)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.action = #selector(onStatusClick)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        model.refresh()
        updateTitle()

        // 若上次开启了固定，启动后直接常驻显示
        if model.pinned {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                self.panelController.show(relativeTo: self.statusItem.button)
            }
        }

        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.model.refresh()
            self?.updateTitle()
        }
        RunLoop.main.add(timer!, forMode: .common)

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(tick),
            name: NSWorkspace.didWakeNotification, object: nil
        )

        // 调试/快捷键入口：外部可发通知让面板弹出
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.local.fundbar.pnl.show"),
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            DebugLog.write("触发 show assets=\(self.model.showAssets) sector=\(self.model.showSector) month=\(self.model.showMonth) hide=\(self.model.hideAmounts) opacity=\(self.model.opacity) funds=\(self.model.snapshot?.funds.count ?? -1)")
            self.panelController.show(relativeTo: self.statusItem.button)
        }
    }

    @objc private func tick() {
        model.refresh()
        updateTitle()
    }

    private func updateTitle() {
        guard let button = statusItem.button else { return }
        let v = model.totalDaily
        button.attributedTitle = NSAttributedString(
            string: signedMoney(v),
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
                .foregroundColor: pnlNSColor(v)
            ]
        )
        button.toolTip = "今日盈亏 \(signedMoney(v))"
    }

    @objc private func onStatusClick() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            model.refresh()
            updateTitle()
            panelController.toggle(relativeTo: statusItem.button)
        }
    }

    private func showMenu() {
        let menu = NSMenu()

        let refresh = NSMenuItem(title: "刷新数据", action: #selector(tick), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let open = NSMenuItem(title: "打开养基宝", action: #selector(openYJB), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)

        let login = NSMenuItem(title: "开机自动启动", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = loginItemEnabled() ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openYJB() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: appBundleID) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.tick() }
    }

    private var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
    }

    private func loginItemEnabled() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    @objc private func toggleLoginItem() {
        let fm = FileManager.default
        if loginItemEnabled() {
            try? fm.removeItem(at: launchAgentURL)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = ["bootout", "gui/\(getuid())/\(launchAgentLabel)"]
            try? p.run()
        } else {
            let exe = Bundle.main.executablePath ?? ""
            let plist: [String: Any] = [
                "Label": launchAgentLabel,
                "ProgramArguments": [exe],
                "RunAtLoad": true,
                "KeepAlive": false
            ]
            if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
                try? fm.createDirectory(at: launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: launchAgentURL)
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
