import AppKit
import Combine
import CoreGraphics
import TrackingCore

@MainActor final class Tracker: ObservableObject {
    static let shared = Tracker()
    @Published private(set) var ledger = Ledger()
    @Published private(set) var coverage = RecordingCoverage()
    @Published private(set) var sources = Source.defaults
    @Published private(set) var running = false
    @Published private(set) var status = "Starting"
    @Published private(set) var browserStatuses: [Browser: String] = [:]
    @Published private(set) var enabledBrowsers: Set<Browser> = [.chrome]
    @Published private(set) var blockedBrowsers: Set<Browser> = []
    @Published var storageError: String?
    @Published var actionError: String?
    @Published var websitesEnabled = false {
        didSet { UserDefaults.standard.set(websitesEnabled, forKey: "websitesEnabled"); resetBrowser() }
    }
    @Published var idleMinutes = 5 {
        didSet { UserDefaults.standard.set(idleMinutes, forKey: "idleMinutes") }
    }
    private var timer: Timer?
    private let browserReader = BrowserTabReader()
    private var requestPending = false
    private var generation = 0
    private var previousApp: String?
    private var suspensionReasons: Set<String> = []
    private var suspended: Bool { !suspensionReasons.isEmpty }
    private var lastSave = Date.distantPast
    private var observers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private let store: TrackingStore
    var dataURL: URL { store.visitsURL }
    func source(for id: Service) -> Source? { sources.first { $0.id == id } }

    private init() {
        store = TrackingStore(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FocusTrace", isDirectory: true))
        let defaults = UserDefaults.standard
        enabledBrowsers = Browser.restoredSelection(saved: defaults.stringArray(forKey: "enabledBrowsers"),
                                                    legacy: defaults.string(forKey: "browser"))
        websitesEnabled = defaults.bool(forKey: "websitesEnabled")
        idleMinutes = defaults.object(forKey: "idleMinutes") == nil ? 5 : defaults.integer(forKey: "idleMinutes")
        do {
            ledger = Ledger(visits: try store.loadVisits())
            coverage = try store.loadCoverage()
            sources = try store.loadSources()
            try store.saveSources(sources)
        } catch {
            storageError = "Could not load or prepare saved data. Tracking stopped to protect your records. \(error.localizedDescription)"
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        })
        for (name, reason) in [(NSWorkspace.willSleepNotification, "system"), (NSWorkspace.screensDidSleepNotification, "display"), (NSWorkspace.sessionDidResignActiveNotification, "session")] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.suspend(reason) }
            })
        }
        for (name, reason) in [(NSWorkspace.didWakeNotification, "system"), (NSWorkspace.screensDidWakeNotification, "display"), (NSWorkspace.sessionDidBecomeActiveNotification, "session")] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.resumeAfterSleep(reason) }
            })
        }
        let distributed = DistributedNotificationCenter.default()
        distributedObservers.append(distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.suspend("lock") }
        })
        distributedObservers.append(distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.resumeAfterSleep("lock") }
        })
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        resetBrowser()
        running = storageError == nil
        if running { tick() }
        else { status = "Storage error" }
    }

    func finish() {
        running = false
        generation += 1
        ledger.stop(at: Date())
        save()
    }

    private func resetBrowser(_ browser: Browser? = nil) {
        generation += 1
        for item in browser.map({ [$0] }) ?? Browser.allCases {
            blockedBrowsers.remove(item)
            browserStatuses[item] = "macOS may ask for access when you next use \(item.name)."
        }
        if running { ledger.stop(at: Date()); save(); tick() }
    }

    func setBrowser(_ browser: Browser, enabled: Bool) {
        if enabled { enabledBrowsers.insert(browser) }
        else { enabledBrowsers.remove(browser) }
        UserDefaults.standard.set(Browser.allCases.filter(enabledBrowsers.contains).map(\.rawValue), forKey: "enabledBrowsers")
        resetBrowser(browser)
    }

    private func suspend(_ reason: String) {
        suspensionReasons.insert(reason); generation += 1
        ledger.stop(at: Date()); save()
        if running { status = "Screen inactive" }
    }

    private func resumeAfterSleep(_ reason: String) {
        suspensionReasons.remove(reason); previousApp = nil; tick()
    }

    private var isIdle: Bool {
        // kCGAnyInputEventType is UInt32.max. `.null` means only null events,
        // and would incorrectly mark an actively used Mac as idle.
        idleMinutes > 0 && CGEventSource.secondsSinceLastEventType(
            .combinedSessionState, eventType: CGEventType(rawValue: UInt32.max)!
        ) >= Double(idleMinutes * 60)
    }

    private func tick() {
        guard running, !suspended, storageError == nil else { return }
        let now = Date()
        coverage.observe(at: now)
        guard !isIdle else {
            generation += 1
            ledger.stop(at: now); status = "Idle"
            saveIfNeeded(); return
        }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let app = frontmost?.bundleIdentifier ?? frontmost?.executableURL?.path
        if app != previousApp {
            generation += 1; previousApp = app
            ledger.stop(at: now); save()
            guard running else { return }
        }
        if let browser = Browser.eligibleBrowser(frontmostID: app, enabled: enabledBrowsers,
                                                 blocked: blockedBrowsers, websitesEnabled: websitesEnabled) {
            readBrowser(browser)
        } else if let app {
            observe(SourceCatalog.app(identifier: app, name: frontmost?.localizedName ?? app, sources: sources), at: now)
        } else {
            ledger.observe(nil, at: now)
            status = "No active app"
        }
        saveIfNeeded()
    }

    private func readBrowser(_ selected: Browser) {
        guard !requestPending else { return }
        requestPending = true
        let token = generation
        let catalog = sources
        Task { [weak self, browserReader] in
            let result = await browserReader.read(selected, sources: catalog)
            guard let self else { return }
            self.requestPending = false
            guard self.running, !self.suspended, !self.isIdle,
                  self.websitesEnabled, self.enabledBrowsers.contains(selected),
                  self.generation == token,
                  NSWorkspace.shared.frontmostApplication?.bundleIdentifier == selected.bundleID else { return }
            if let errorCode = result.errorCode {
                self.observe(SourceCatalog.app(identifier: selected.bundleID, name: selected.name, sources: self.sources), at: Date())
                if errorCode == -1743 {
                    self.blockedBrowsers.insert(selected)
                    self.browserStatuses[selected] = "Allow \(selected.name) in System Settings → Privacy & Security → Automation, then retry."
                } else {
                    self.browserStatuses[selected] = "Could not read the active tab (\(errorCode)). Retrying."
                }
                if self.running { self.status = "Tracking \(selected.name) · website access needed" }
            } else {
                let source = result.source ?? SourceCatalog.app(identifier: selected.bundleID, name: selected.name, sources: self.sources)
                self.observe(source, at: Date())
                self.browserStatuses[selected] = "Connected to \(selected.name)."
            }
            self.saveIfNeeded()
        }
    }

    private func observe(_ source: Source, at now: Date) {
        do {
            var next = sources
            if let index = next.firstIndex(where: { $0.id == source.id }) {
                next[index].archived = false
            } else {
                next.append(source)
            }
            // Persist the identity before a visit can reference it.
            if next != sources {
                try store.saveSources(next)
                sources = next
            }
            ledger.observe(source.id, at: now)
            status = "Tracking \(source.name)"
        } catch {
            ledger.stop(at: now)
            running = false
            status = "Storage error"
            storageError = "Could not save sources. Tracking stopped. \(error.localizedDescription)"
        }
    }

    private func saveIfNeeded() {
        if Date().timeIntervalSince(lastSave) >= 5 { save() }
    }

    private func save() {
        guard storageError == nil else { return }
        do {
            try store.saveVisits(ledger.visits)
            try store.saveCoverage(coverage)
            lastSave = Date()
        } catch {
            running = false
            status = "Storage error"
            storageError = "Could not save records. Tracking stopped. \(error.localizedDescription)"
        }
    }

    func retryBrowser(_ browser: Browser) { resetBrowser(browser) }

    func addWebsite(name: String, domain: String) throws {
        guard let host = Source.normalizedDomain(domain) else {
            throw SourceInputError("Enter a valid domain, such as reddit.com.")
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try addSource(Source(name: trimmed.isEmpty ? host : trimmed, kind: .website, identifier: host, isDistracting: true))
    }

    func addApp(at url: URL) throws {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else {
            throw SourceInputError("Choose a Mac application.")
        }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        try addSource(Source(name: name, kind: .app, identifier: id, isDistracting: true))
    }

    private func addSource(_ source: Source) throws {
        var next = sources
        if let index = next.firstIndex(where: { $0.kind == source.kind && ([$0.identifier] + $0.aliases).contains(source.identifier) }) {
            next[index].archived = false
            next[index].isDistracting = true
        } else { next.append(source) }
        try updateSources(next)
    }

    func setDistracting(_ source: Source, enabled: Bool) {
        var next = sources
        guard let index = next.firstIndex(where: { $0.id == source.id }) else { return }
        next[index].isDistracting = enabled
        do { try updateSources(next) }
        catch { actionError = error.localizedDescription }
    }

    private func updateSources(_ next: [Source]) throws {
        guard storageError == nil else { throw SourceInputError("Resolve the storage error before changing sources.") }
        try store.saveSources(next)
        generation += 1
        sources = next
    }

    func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "FocusTrace.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try VisitCSV.export(ledger.visits, sources: sources)
                .write(to: url, atomically: true, encoding: .utf8)
        }
        catch {
            actionError = "Export failed. \(error.localizedDescription)"
        }
    }
}

private struct SourceInputError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
