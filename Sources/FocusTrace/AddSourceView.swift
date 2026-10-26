import AppKit
import SwiftUI
import TrackingCore
import UniformTypeIdentifiers

struct AddSourceView: View {
    @ObservedObject var tracker: Tracker
    let dismiss: () -> Void
    @State private var kind: Source.Kind = .website
    @State private var name = ""
    @State private var domain = ""
    @State private var appURL: URL?
    @State private var error: String?
    @FocusState private var domainFocused: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Add distraction").font(AppType.dialogTitle)
                Spacer()
                DialogCloseButton(action: dismiss)
            }
            Text("All apps and sites are recorded automatically. Add a service here to mark it as distracting before you use it.")
                .font(.callout).foregroundStyle(.secondary)
            Picker("Type", selection: $kind) {
                Text("Website").tag(Source.Kind.website)
                Text("Mac app").tag(Source.Kind.app)
            }.pickerStyle(.segmented).labelsHidden()
            if kind == .website {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Domain").font(.callout)
                    TextField("reddit.com", text: $domain).textFieldStyle(.roundedBorder).focused($domainFocused)
                    Text("Includes subdomains.").font(AppType.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Name (optional)").font(.callout)
                    TextField("Reddit", text: $name).textFieldStyle(.roundedBorder)
                }
                if !tracker.websitesEnabled {
                    Text("Website tracking is off. Enable it in Settings to record this source.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Text(appURL?.deletingPathExtension().lastPathComponent ?? "No app selected").lineLimit(1)
                    Spacer()
                    Button("Choose app…", action: chooseApp)
                }.padding(.vertical, 10)
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Add distraction", action: add).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(kind == .website ? domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : appURL == nil)
            }
        }
        .padding(AppLayout.pageInset).frame(width: 430)
        .onAppear { domainFocused = true }
        .onChange(of: kind) { _ in error = nil }
    }
    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.begin { response in
            if response == .OK { appURL = panel.url; error = nil }
        }
    }
    private func add() {
        do {
            if kind == .website { try tracker.addWebsite(name: name, domain: domain) }
            else if let appURL { try tracker.addApp(at: appURL) }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
