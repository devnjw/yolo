import AppKit
import Combine
import CoreGraphics
import TrackingCore
import UniformTypeIdentifiers

@MainActor final class Tracker: ObservableObject {
    static let shared = Tracker()
    @Published private(set) var ledger = Ledger()
    @Published private(set) var coverage = RecordingCoverage()
    @Published private(set) var sources = Source.defaults
    @Published private(set) var categories = CategoryCatalog()
    @Published private(set) var running = false
    @Published private(set) var status = "Starting"
    @Published private(set) var browserStatuses: [Browser: String] = [:]
    @Published private(set) var enabledBrowsers: Set<Browser> = [.chrome]
    @Published private(set) var blockedBrowsers: Set<Browser> = []
    @Published var storageError: String?
    @Published var actionError: String?
    @Published var websitesEnabled = false {
        didSet {
            guard !applyingOptions else { return }
            do { try persistOptions(); resetBrowser() }
            catch { applyingOptions = true; websitesEnabled = oldValue; applyingOptions = false; actionError = error.localizedDescription }
        }
    }
    @Published var idleMinutes = 5 {
        didSet {
            guard !applyingOptions else { return }
            do { try persistOptions() }
            catch { applyingOptions = true; idleMinutes = oldValue; applyingOptions = false; actionError = error.localizedDescription }
        }
    }
    private var timer: Timer?
    private let browserReader = BrowserTabReader()
    private var requestPending = false
    private var generation = 0
    private var previousApp: String?
    private var previousProcessIdentifier: pid_t?
    private var suspensionReasons: Set<String> = []
    private var suspended: Bool { !suspensionReasons.isEmpty }
    private var lastSave = Date.distantPast
    private var observers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private let dataDirectory: URL
    private let backupRepository: RecordingBackups
    private let observesSystem: Bool
    private var finishing = false
    private var applyingOptions = false
    private var storageEpoch: UInt64 = 0
    private var lastAutomaticBackupCheck = Date.distantPast
    @Published private(set) var backupBusy = false
    @Published private(set) var restoring = false
    @Published private(set) var lastAutomaticBackup: Date?
    @Published private(set) var backupMessage: String?
    @Published private(set) var backupError: String?
    var backupsURL: URL { backupRepository.directory }
    var canRestoreBackup: Bool { recordingLease != nil && !backupBusy && !restoring && !finishing }
    private var recordingLease: RecordingLease?
    private var recordingWriter: RecordingWriter?
    private var savedVisitCount = 0
    private var savedCoverageCount = 0
    private var saveInFlight = false
    private var saveRequested = false
    var dataURL: URL { dataDirectory.appendingPathComponent("recording.sqlite3") }
    func source(for id: Service) -> Source? { sources.first { $0.id == id } }

    init(directory: URL? = nil, backupDirectory: URL? = nil, defaults: UserDefaults = .standard, observesSystem: Bool = true) {
        self.observesSystem = observesSystem
        dataDirectory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FocusTrace", isDirectory: true)
        backupRepository = RecordingBackups(directory: backupDirectory ?? dataDirectory.deletingLastPathComponent()
            .appendingPathComponent("FocusTrace Backups", isDirectory: true))
        let legacyOptions = TrackingOptions(websitesEnabled: defaults.bool(forKey: "websitesEnabled"),
            enabledBrowsers: Browser.restoredSelection(saved: defaults.stringArray(forKey: "enabledBrowsers"), legacy: defaults.string(forKey: "browser")),
            idleMinutes: defaults.object(forKey: "idleMinutes") == nil ? 5 : defaults.integer(forKey: "idleMinutes"))
        do {
            if observesSystem && NSRunningApplication.runningApplications(withBundleIdentifier: "local.jinwoo.FocusTrace")
                .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
                throw RecordingDatabaseError("Another copy of FocusTrace is running. Quit that copy before opening this version.")
            }
            recordingLease = try RecordingLease(directory: dataDirectory)
            let database = try RecordingDatabase(directory: dataDirectory, legacyOptions: legacyOptions,
                migrationBackupDirectory: backupRepository.directory.appendingPathComponent("Migrations", isDirectory: true))
            applySnapshot(try database.loadSnapshot())
            recordingWriter = RecordingWriter(database: database)
        } catch {
            storageError = "Could not load or prepare saved data. Tracking stopped to protect your records. \(error.localizedDescription)"
        }
        guard observesSystem else {
            running = storageError == nil
            status = running ? "Starting" : "Storage error"
            return
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
        finishing = true
        running = false
        generation += 1
        ledger.stop(at: Date())
        guard let recordingWriter else { return }
        do {
            // Even after a source/configuration error, drain previously submitted
            // valid writes. Do not add records collected after an error.
            try recordingWriter.finish(visits: storageError == nil && !restoring ? ledger.recordsToSave(after: savedVisitCount) : [],
                                       coverage: storageError == nil && !restoring ? coverageRecordsToSave() : [])
        } catch { recordingFailed(error) }
    }

    private func resetBrowser(_ browser: Browser? = nil) {
        generation += 1
        for item in browser.map({ [$0] }) ?? Browser.allCases {
            blockedBrowsers.remove(item)
            browserStatuses[item] = "macOS may ask for access when you next use \(item.name)."
        }
        if running { ledger.stop(at: Date()); save(); tick() }
    }

    private var trackingOptions: TrackingOptions {
        TrackingOptions(websitesEnabled: websitesEnabled, enabledBrowsers: enabledBrowsers, idleMinutes: idleMinutes)
    }
    private func persistOptions() throws {
        guard storageError == nil, !restoring, let recordingWriter else { throw SourceInputError("Tracking settings are temporarily unavailable.") }
        try recordingWriter.saveOptions(trackingOptions)
    }
    func setBrowser(_ browser: Browser, enabled: Bool) {
        var next = enabledBrowsers
        if enabled { next.insert(browser) } else { next.remove(browser) }
        do {
            guard storageError == nil, !restoring, let recordingWriter else { throw SourceInputError("Tracking settings are temporarily unavailable.") }
            var options = trackingOptions; options.enabledBrowsers = next
            try recordingWriter.saveOptions(options)
            enabledBrowsers = next
            resetBrowser(browser)
        } catch { actionError = error.localizedDescription }
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
        guard observesSystem, !finishing, running, !suspended, storageError == nil else { return }
        let now = Date()
        coverage.observe(at: now)
        defer { checkAutomaticBackup(at: now) }
        guard !isIdle else {
            generation += 1
            ledger.stop(at: now); status = "Idle"
            saveIfNeeded(); return
        }
        let frontmost = NSWorkspace.shared.frontmostApplication
        let app = frontmost?.bundleIdentifier ?? frontmost?.executableURL?.path
        if app != previousApp || frontmost?.processIdentifier != previousProcessIdentifier {
            generation += 1; previousApp = app
            previousProcessIdentifier = frontmost?.processIdentifier
            ledger.stop(at: now); save()
            guard running else { return }
        }
        if let frontmost, let browser = Browser.eligibleBrowser(frontmostID: app, enabled: enabledBrowsers,
                                                 blocked: blockedBrowsers, websitesEnabled: websitesEnabled) {
            readBrowser(.init(browser: browser, processIdentifier: frontmost.processIdentifier))
        } else if let app {
            observe(SourceCatalog.app(identifier: app, name: frontmost?.localizedName ?? app, sources: sources), at: now)
        } else {
            ledger.observe(nil, at: now)
            status = "No active app"
        }
        saveIfNeeded()
    }

    private func readBrowser(_ target: BrowserTabReader.Target) {
        guard !requestPending else { return }
        requestPending = true
        let selected = target.browser
        let token = generation
        let catalog = sources
        Task { [weak self, browserReader] in
            let result = await browserReader.read(target, sources: catalog)
            guard let self else { return }
            self.requestPending = false
            let frontmost = NSWorkspace.shared.frontmostApplication
            guard self.running, !self.suspended, !self.isIdle,
                  self.websitesEnabled, self.enabledBrowsers.contains(selected),
                  self.generation == token,
                  target.matches(bundleIdentifier: frontmost?.bundleIdentifier,
                                 processIdentifier: frontmost?.processIdentifier) else { return }
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
                self.browserStatuses[selected] = result.source == nil
                    ? "No website in the active tab. Tracking \(selected.name) as an app."
                    : "Connected to \(selected.name)."
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
                try updateSources(next)
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

    private func coverageRecordsToSave() -> [(ordinal: Int, interval: DateInterval)] {
        let first = max(0, savedCoverageCount - 1)
        return coverage.intervals.indices.dropFirst(first).map { ($0, coverage.intervals[$0]) }
    }

    func save() {
        guard storageError == nil, !restoring, !finishing, let recordingWriter else { return }
        // Coalesce requests while disk I/O is pending. Never enqueue snapshots of
        // the entire history, or an unbounded backlog when a disk is slow.
        guard !saveInFlight else { saveRequested = true; return }
        let visits = ledger.recordsToSave(after: savedVisitCount)
        let intervals = coverageRecordsToSave()
        savedVisitCount = ledger.visitCount
        savedCoverageCount = coverage.intervals.count
        lastSave = Date()
        saveInFlight = true
        let epoch = storageEpoch
        recordingWriter.submit(visits: visits, coverage: intervals) { [weak self] result in
            Task { @MainActor in
                guard let self, self.storageEpoch == epoch else { return }
                self.saveInFlight = false
                switch result {
                case .failure(let error): self.recordingFailed(error)
                case .success:
                    if self.saveRequested && self.running {
                        self.saveRequested = false
                        self.save()
                    }
                }
            }
        }
    }

    private func recordingFailed(_ error: Error) {
        running = false
        generation += 1
        ledger.stop(at: Date())
        status = "Storage error"
        storageError = "Could not save records. Tracking stopped. \(error.localizedDescription)"
    }

    func retryBrowser(_ browser: Browser) { resetBrowser(browser) }

    func addWebsite(name: String, domain: String) throws {
        guard let host = Source.normalizedDomain(domain) else {
            throw SourceInputError("Enter a valid domain, such as reddit.com.")
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        try addSource(Source(name: trimmed.isEmpty ? host : trimmed, kind: .website, identifier: host))
    }

    func addApp(at url: URL) throws {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else {
            throw SourceInputError("Choose a Mac application.")
        }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        try addSource(Source(name: name, kind: .app, identifier: id))
    }

    private func addSource(_ source: Source) throws {
        var next = sources
        if let index = next.firstIndex(where: { $0.kind == source.kind && ([$0.identifier] + $0.aliases).contains(source.identifier) }) {
            next[index].archived = false
        } else { next.append(source) }
        try updateSources(next)
    }

    func setCategory(_ categoryID: String, for groupID: String) {
        do { try editCategories { try $0.assign(categoryID, to: groupID) } }
        catch { actionError = error.localizedDescription }
    }

    func renameService(_ id: String, to name: String) throws {
        try editCategories { try $0.renameService(id, to: name, sources: sources) }
    }

    func mergeService(_ id: String, into destination: String, name: String, categoryID: String) throws {
        try editCategories { try $0.mergeService(id, into: destination, name: name, categoryID: categoryID, sources: sources) }
    }

    func splitServiceMember(_ source: Source, from groupID: String, name: String) throws -> String {
        var result = ""
        try editCategories { result = try $0.splitServiceMember(source.id, from: groupID, name: name, sources: sources) }
        return result
    }

    func selectCategories(_ ids: Set<String>?) {
        do { try editCategories { try $0.select(ids) } }
        catch { actionError = error.localizedDescription }
    }

    func createCategory(name: String, tint: ActivityCategory.Tint, customHex: UInt32?, assigning groupID: String? = nil) throws {
        try editCategories { try $0.create(name: name, tint: tint, customHex: customHex, assigning: groupID) }
    }
    func updateCategory(_ id: String, name: String, tint: ActivityCategory.Tint, customHex: UInt32?) throws {
        try editCategories { try $0.update(id, name: name, tint: tint, customHex: customHex) }
    }
    func removeCategory(_ id: String, movingTo destination: String) throws {
        try editCategories { try $0.remove(id, movingTo: destination) }
    }
    private func editCategories(_ edit: (inout CategoryCatalog) throws -> Void) throws {
        guard storageError == nil, !restoring, let recordingWriter else { throw CategoryError("Services and categories are temporarily unavailable.") }
        var next = categories
        try edit(&next)
        try recordingWriter.saveCatalog(sources: sources, categories: next)
        categories = next
    }

    private func updateSources(_ next: [Source]) throws {
        guard storageError == nil, !restoring, let recordingWriter else { throw SourceInputError("Services are temporarily unavailable.") }
        var nextCategories = categories
        nextCategories.applyServiceDefaults(to: next)
        try recordingWriter.saveCatalog(sources: next, categories: nextCategories)
        categories = nextCategories
        generation += 1
        sources = next
    }

    private func applySnapshot(_ snapshot: RecordingSnapshot) {
        ledger = Ledger(visits: snapshot.visits)
        coverage = snapshot.coverage
        sources = snapshot.sources
        categories = snapshot.categories
        applyingOptions = true
        websitesEnabled = snapshot.options.websitesEnabled
        enabledBrowsers = snapshot.options.enabledBrowsers
        idleMinutes = snapshot.options.idleMinutes
        applyingOptions = false
        savedVisitCount = ledger.visitCount
        savedCoverageCount = coverage.intervals.count
    }

    private func checkAutomaticBackup(at now: Date) {
        guard storageError == nil, !backupBusy, !restoring,
              now.timeIntervalSince(lastAutomaticBackupCheck) >= 3600 else { return }
        lastAutomaticBackupCheck = now
        beginBackup(destination: nil)
    }

    func exportBackup() {
        guard !backupBusy, !restoring, storageError == nil else { return }
        backupBusy = true
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "FocusTrace-backup.sqlite3"
        panel.allowedContentTypes = [UTType(filenameExtension: "sqlite3") ?? .data]
        let result = panel.runModal()
        backupBusy = false
        guard result == .OK, let url = panel.url else { return }
        beginBackup(destination: url)
    }

    private func beginBackup(destination: URL?) {
        guard !backupBusy, !restoring, storageError == nil, let recordingWriter else { return }
        backupBusy = true; backupError = nil; backupMessage = nil
        recordingWriter.backup(visits: ledger.recordsToSave(after: savedVisitCount), coverage: coverageRecordsToSave(),
                               destination: destination, repository: backupRepository) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.backupBusy = false
                switch result {
                case .success(let entry):
                    if destination == nil { self.lastAutomaticBackup = entry.date }
                    else { self.backupMessage = "Backup saved." }
                case .failure(let error):
                    self.backupError = error.localizedDescription
                    if error is RecordingWriteFailure { self.recordingFailed(error) }
                }
            }
        }
    }

    func chooseBackupToRestore() {
        guard canRestoreBackup else { return }
        backupBusy = true
        let selected = confirmedBackupToRestore()
        backupBusy = false
        if let selected { restoreBackup(from: selected) }
    }

    private func confirmedBackupToRestore() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "sqlite3") ?? .data]
        panel.message = "Choose a FocusTrace database backup."
        if FileManager.default.fileExists(atPath: backupRepository.automaticDirectory.path) { panel.directoryURL = backupRepository.automaticDirectory }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let alert = NSAlert()
        alert.messageText = "Restore this backup?"
        alert.informativeText = "Current records, services, categories and tracking settings will be replaced. A recovery backup of your current data will be saved first."
        alert.addButton(withTitle: "Restore"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return url
    }

    func restoreBackup(from url: URL) {
        guard canRestoreBackup else { return }
        guard let recordingWriter else { recoverClosedDatabase(from: url); return }
        guard storageError == nil else {
            backupError = "Restart FocusTrace before restoring after a recording error."; return
        }
        let wasRunning = running
        running = false; restoring = true; backupBusy = true
        backupError = nil; backupMessage = nil
        generation += 1; storageEpoch &+= 1
        saveInFlight = false; saveRequested = false
        ledger.stop(at: Date())
        recordingWriter.restore(visits: ledger.recordsToSave(after: savedVisitCount), coverage: coverageRecordsToSave(),
                                from: url, repository: backupRepository) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.backupBusy = false; self.restoring = false
                guard !self.finishing else { return }
                switch result {
                case .success(let restored):
                    self.applySnapshot(restored.snapshot)
                    self.resetBrowser()
                    self.backupMessage = "Backup restored. Your previous data is saved in the Recovery backup folder."
                case .failure(let error):
                    self.backupError = error.localizedDescription
                    if error is RecordingWriteFailure || error is RecordingRestoreRecoveryError {
                        self.recordingFailed(error); return
                    }
                    // The writer committed the latest tail before validating the
                    // backup. Failed replacement rolls back to that same state.
                    self.savedVisitCount = self.ledger.visitCount
                    self.savedCoverageCount = self.coverage.intervals.count
                }
                self.lastSave = Date(); self.previousApp = nil
                self.running = wasRunning
                self.status = self.suspended ? "Screen inactive" : "Starting"
                if self.running { self.tick() }
            }
        }
    }

    private func recoverClosedDatabase(from url: URL) {
        restoring = true; backupBusy = true; backupError = nil; backupMessage = nil
        generation += 1; storageEpoch &+= 1
        let directory = dataDirectory, repository = backupRepository
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result: Result<(RecordingWriter, RecordingSnapshot), Error>
            do {
                let recoveryURL = try repository.recoveryURL()
                let database = try RecordingDatabase.recoverClosedDatabase(at: directory.appendingPathComponent("recording.sqlite3"),
                    from: url, recoveryURL: recoveryURL)
                let snapshot = try database.loadSnapshot()
                result = .success((RecordingWriter(database: database), snapshot))
            } catch { result = .failure(error) }
            Task { @MainActor in
                guard let self else { return }
                self.restoring = false; self.backupBusy = false
                guard !self.finishing else { return }
                switch result {
                case .success(let (writer, snapshot)):
                    self.recordingWriter = writer; self.applySnapshot(snapshot)
                    self.storageError = nil; self.resetBrowser()
                    self.running = true; self.previousApp = nil
                    self.lastSave = Date(); self.lastAutomaticBackupCheck = .distantPast
                    self.backupMessage = "Backup restored. The previous database is preserved in the Recovery folder."
                    self.tick()
                case .failure(let error): self.backupError = error.localizedDescription
                }
            }
        }
    }

    func openBackupsFolder() {
        do {
            try FileManager.default.createDirectory(at: backupsURL, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            NSWorkspace.shared.open(backupsURL)
        } catch { backupError = error.localizedDescription }
    }

    func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "FocusTrace.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try VisitCSV.export(ledger.visits, sources: sources, categories: categories)
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
