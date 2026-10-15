import SwiftUI
import ZimmerKit

/// The web UI's new-session form, as a native form: agent root, runtime, model, effort, the
/// auto-compact window (Claude Code only), prompt, title, goal, scheduling class and
/// precedence, the MCP servers, skills, hooks and plugins the session carries — each starting
/// at the root's defaults, as the web form does — and *Clone Only*. The class starts at *From
/// its origin* and sends nothing, as the web form's default does; the server classes a create
/// from the app priority, since a person is waiting on it.
struct NewSessionView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var configs: AppConfigs?
    @State private var root: String = ""
    @State private var runtime: String = "claude_code"
    @State private var modelID: String = ""
    @State private var effort: String = ""
    @State private var prompt = ""
    @State private var title = ""
    @State private var goal = ""
    @State private var schedulingClass = ""
    /// The web form's number fields, as typed: blank is the server's default.
    @State private var precedence = ""
    @State private var autoCompactWindow = ""
    @State private var selections: [CatalogKind: [String]] = [:]
    @State private var starting = false
    @State private var error: ZimmerError?
    /// A field the form refuses before sending, as the web's number inputs refuse it.
    @State private var validation: String?
    /// One attempt's key, kept across retries of the same request so a lost response cannot
    /// start a second session — and replaced the moment the request changes, so an edited
    /// retry is never answered with the session the first one made.
    @State private var idempotencyKey = UUID().uuidString
    @State private var lastAttempt: String?
    /// What `apply(root:)` filled in, so only a runtime or model the person chose, or the root
    /// names, is sent; otherwise the server's own defaults (Settings) apply.
    @State private var appliedRuntime = ""
    @State private var appliedModel = ""
    @State private var rootDeclares = (runtime: false, model: false)

    var body: some View {
        NavigationStack {
            Form {
                if let error {
                    Section { ErrorBanner(error: error).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
                }
                if let validation {
                    Section {
                        Label(validation, systemImage: "exclamationmark.circle")
                            .font(.subheadline)
                            .foregroundStyle(Theme.danger)
                            .accessibilityIdentifier("newsession.validation")
                    }
                    .themeRows()
                }
                Group {
                    if let configs {
                        form(configs)
                    } else if error == nil {
                        Section { LoadingState().padding(.vertical, 8) }
                    }
                }
                .themeRows()
            }
            .themeGround()
            .navigationTitle("New session")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(starting ? "Creating…" : "Create") { Task { await create() } }
                        .disabled(starting || root.isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("newsession.create")
                }
            }
            .task { await load() }
        }
    }

    @ViewBuilder
    private func form(_ configs: AppConfigs) -> some View {
        agentSection(configs)
        promptSection
        goalSection(configs)
        schedulingSection
        artifactsSection
        cloneOnlySection
    }

    private func agentSection(_ configs: AppConfigs) -> some View {
        Section {
            Picker("Agent root", selection: $root) {
                ForEach(configs.invocableRoots) { root in Text(root.title).tag(root.name) }
            }
            .accessibilityIdentifier("newsession.root")
            if configs.runtimeModels.count > 1 {
                Picker("Runtime", selection: $runtime) {
                    ForEach(configs.runtimeModels.keys.sorted(), id: \.self) { Text($0).tag($0) }
                }
            }
            Picker("Model", selection: $modelID) {
                if configs.models(for: runtime).isEmpty { Text("Default").tag("") }
                ForEach(configs.models(for: runtime)) { model in Text(model.title).tag(model.id) }
            }
            .accessibilityIdentifier("newsession.model")
            if let model = configs.models(for: runtime).first(where: { $0.id == modelID }), !model.effortLevels.isEmpty {
                let modelDefault = model.defaultEffort.map { "Model default (\($0))" } ?? "Model default"
                Picker("Reasoning effort", selection: $effort) {
                    Text(modelDefault).tag("")
                    ForEach(model.effortLevels, id: \.self) { Text($0).tag($0) }
                }
            }
            // The web form's field, shown for Claude Code alone, as its controller shows it.
            if runtime == "claude_code" {
                LabeledContent("Auto-compact window") {
                    TextField(NewSessionRequest.maxAutoCompactWindow.formatted(), text: $autoCompactWindow)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("newsession.autocompact")
                }
            }
        } header: {
            Text("Agent")
        } footer: {
            if runtime == "claude_code" {
                Text("Claude Code's context-compaction threshold, in tokens. Blank is the default, 1,000,000, which is also the most it takes. Only a Claude Code session honours it.")
            }
        }
        .onChange(of: root) { _, name in
            if let option = configs.agentRoots.first(where: { $0.name == name }) { apply(root: option, in: configs) }
        }
        .onChange(of: runtime) { _, runtime in
            if !configs.models(for: runtime).contains(where: { $0.id == modelID }) {
                modelID = configs.runtimeModels[runtime]?.default ?? configs.models(for: runtime).first?.id ?? ""
                effort = ""
            }
        }
        .onChange(of: modelID) { _, id in
            // A level the new model does not take is dropped, as the web form's effort picker does.
            let levels = configs.models(for: runtime).first { $0.id == id }?.effortLevels ?? []
            if !levels.contains(effort) { effort = "" }
        }
    }

    private var promptSection: some View {
        Section("Prompt") {
            TextField("What should the agent do?", text: $prompt, axis: .vertical)
                .lineLimit(4...12)
                .accessibilityIdentifier("newsession.prompt")
            TextField("Title (optional)", text: $title)
        }
    }

    private func goalSection(_ configs: AppConfigs) -> some View {
        Section {
            Picker("Goal", selection: goalPreset(configs)) {
                Text("None").tag("")
                ForEach(configs.goals) { goal in Text(goal.name ?? goal.id).tag(goal.id) }
                Text("Custom…").tag(Self.customGoal)
            }
            if !configs.goals.contains(where: { $0.id == goal }) && !goal.isEmpty || goalIsCustom {
                TextField("When is this session done?", text: $goal, axis: .vertical)
                    .lineLimit(2...6)
            }
        } header: {
            Text("Goal")
        }
    }

    private var schedulingSection: some View {
        Section {
            // The web select's three, in its order with its words; "from its origin" names what
            // the app's origin gives, as the web names the web app's.
            Picker("Scheduling class", selection: $schedulingClass) {
                Text("From its origin — priority, started from the app").tag("")
                Text("Priority — starts whenever it is ready").tag("priority")
                Text("Spot — waits for quota room or a free slot").tag("spot")
            }
            .accessibilityIdentifier("newsession.class")
            LabeledContent("Precedence") {
                TextField("0", text: $precedence)
                    .keyboardType(.numbersAndPunctuation)
                    .multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("newsession.precedence")
            }
        } header: {
            Text("Scheduling")
        } footer: {
            Text("Spot sessions start only while a Claude Code account is under both quota targets and a session slot is free; otherwise they wait, never cancelled, and are worked highest precedence first on an absolute scale — 100000 comes before 50 — and nothing renumbers, so leave gaps. Blank is 0. Anything this session spawns inherits the class. A session started from the app is priority unless you pick otherwise.")
        }
    }

    /// The web form's *Clone Only*: the clone is set up and no turn runs; the prompt is dropped,
    /// as the web button drops it, and the first message is sent from the session's page.
    private var cloneOnlySection: some View {
        Section {
            Button("Clone Only") { Task { await create(cloneOnly: true) } }
                .disabled(starting || root.isEmpty)
                .accessibilityIdentifier("newsession.cloneonly")
        } footer: {
            Text("Set the clone up without a first turn. The prompt is dropped; send the first message from the session's page.")
        }
    }

    private var artifactsSection: some View {
        Section("Artifacts") {
            ForEach(CatalogKind.allCases) { kind in
                NavigationLink {
                    CatalogPicker(kind: kind, selection: binding(for: kind))
                } label: {
                    LabeledContent(kind.label, value: summary(selections[kind] ?? []))
                }
                .accessibilityIdentifier("newsession.catalog.\(kind.rawValue)")
            }
        }
    }

    private static let customGoal = "\u{1}custom"
    @State private var goalIsCustom = false

    /// The goal picker: a predefined goal's id, none, or custom text in the field below.
    private func goalPreset(_ configs: AppConfigs) -> Binding<String> {
        Binding(
            get: { goalSelection(configs) },
            set: { value in
                goalIsCustom = value == Self.customGoal
                // Custom starts empty, not with the preset's id in the box.
                goal = value == Self.customGoal ? "" : value
            }
        )
    }

    private func goalSelection(_ configs: AppConfigs) -> String {
        if goalIsCustom { return Self.customGoal }
        if goal.isEmpty { return "" }
        let preset = configs.goals.contains { $0.id == goal }
        return preset ? goal : Self.customGoal
    }

    private func binding(for kind: CatalogKind) -> Binding<[String]> {
        Binding(get: { selections[kind] ?? [] }, set: { selections[kind] = $0 })
    }

    private func summary(_ values: [String]) -> String {
        switch values.count {
        case 0: return "None"
        case 1: return values[0]
        default: return "\(values.count) chosen"
        }
    }

    private func load() async {
        guard configs == nil else { return }
        do {
            let loaded = try await app.api.configs()
            configs = loaded
            if let first = loaded.invocableRoots.first(where: { $0.isDefault == true }) ?? loaded.invocableRoots.first {
                apply(root: first, in: loaded)
            }
            error = nil
        } catch {
            self.error = error as? ZimmerError ?? .transport(error)
        }
    }

    /// Choosing a root resets what follows it to that root's defaults, as the web form does.
    private func apply(root option: AgentRootOption, in configs: AppConfigs) {
        root = option.name
        runtime = option.defaultRuntime ?? "claude_code"
        // The root's model only if its runtime lists it; else the runtime's default — the web
        // form's model picker does the same.
        let allowed = configs.models(for: runtime).map(\.id)
        if let rootModel = option.defaultModel, allowed.contains(rootModel) {
            modelID = rootModel
        } else {
            modelID = configs.runtimeModels[runtime]?.default ?? allowed.first ?? ""
        }
        appliedRuntime = runtime
        appliedModel = modelID
        rootDeclares = (option.defaultRuntime != nil, option.defaultModel.map(allowed.contains) ?? false)
        effort = ""
        // A new root brings its own goal, or none, as the web form does.
        goal = option.defaultGoal ?? ""
        goalIsCustom = false
        for kind in CatalogKind.allCases { selections[kind] = kind.defaults(of: option) }
    }

    /// Blank number fields send nothing; one that is not a whole number is refused here, where
    /// the web's number inputs refuse it, rather than sent as nothing.
    private enum NumberField {
        case value(Int?)
        case refused(String)
    }

    private func wholeNumber(_ text: String, named name: String) -> NumberField {
        let trimmed = text.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return .value(nil) }
        guard let value = Int(trimmed) else { return .refused("\(name) must be a whole number") }
        return .value(value)
    }

    private func create(cloneOnly: Bool = false) async {
        starting = true
        defer { starting = false }
        let rank: Int?
        let window: Int?
        switch (wholeNumber(precedence, named: "Precedence"), wholeNumber(autoCompactWindow, named: "Auto-compact window")) {
        case let (.value(p), .value(w)):
            rank = p
            window = w
            validation = nil
        case let (.refused(refusal), _), let (_, .refused(refusal)):
            validation = refusal
            return
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        // A predefined goal is stored as its words, as the web form stores it.
        let goalText = configs?.goals.first { $0.id == trimmedGoal }?.description ?? trimmedGoal
        let sendRuntime = rootDeclares.runtime || runtime != appliedRuntime
        let sendModel = !modelID.isEmpty && (rootDeclares.model || modelID != appliedModel || sendRuntime)
        var request = NewSessionRequest(
            agentRoot: root, prompt: cloneOnly ? "" : prompt.trimmingCharacters(in: .whitespacesAndNewlines),
            runtime: sendRuntime ? runtime : nil, model: sendModel ? modelID : nil, effort: effort.isEmpty ? nil : effort,
            title: trimmedTitle.isEmpty ? nil : trimmedTitle, goal: goalText.isEmpty ? nil : goalText,
            schedulingClass: schedulingClass.isEmpty ? nil : schedulingClass, precedence: rank,
            // A disabled web input is left out of the submit; the field is only shown for Claude Code.
            autoCompactWindow: runtime == "claude_code" ? window : nil, cloneOnly: cloneOnly,
            selections: selections, idempotencyKey: idempotencyKey
        )
        let attempt = request.fingerprint
        if let lastAttempt, lastAttempt != attempt {
            idempotencyKey = UUID().uuidString
            request.idempotencyKey = idempotencyKey
        }
        lastAttempt = attempt
        if let session = await app.createSession(request) {
            dismiss()
            app.path.append(session.id)
        } else {
            // Shown here, over the list the error also reached.
            error = app.error
        }
    }
}

/// Choose a session's MCP servers, skills, hooks or plugins from the catalog: a checklist,
/// searchable, with an unavailable MCP server saying why and listed last, as the web's are.
/// A chosen id the catalog no longer lists is shown, unticked: the server refuses a list
/// that names it, so saving drops it.
struct CatalogPicker: View {
    @EnvironmentObject private var app: AppModel
    let kind: CatalogKind
    @Binding var selection: [String]
    @State private var items: [CatalogItem]?
    @State private var error: ZimmerError?
    @State private var query = ""
    /// The chosen ids the catalog did not list when it read.
    @State private var initialMissing: [String] = []

    var body: some View {
        List {
            if let error { ErrorBanner(error: error).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
            ForEach(filtered) { item in
                Button {
                    toggle(item.id)
                } label: {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.displayTitle).foregroundStyle(Theme.ink)
                            if let reason = item.unavailableReason {
                                Label(reason, systemImage: "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(Theme.warning)
                            } else if let description = item.description, !description.isEmpty {
                                Text(description).font(.caption).foregroundStyle(Theme.inkSoft).lineLimit(2)
                            }
                        }
                        Spacer()
                        if selection.contains(item.id) {
                            Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Theme.accent)
                        }
                    }
                }
                .accessibilityIdentifier("catalog.item.\(item.id)")
                .accessibilityAddTraits(selection.contains(item.id) ? .isSelected : [])
                .themeRows()
            }
            // Not a toggle: the server refuses a list naming one.
            ForEach(missing, id: \.self) { id in
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: id).foregroundStyle(Theme.inkSoft).strikethrough()
                    Text("Not in the catalog any more; saving drops it").font(.caption).foregroundStyle(Theme.warning)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("catalog.missing.\(id)")
                .themeRows()
            }
        }
        .themeGround()
        .overlay { if items == nil && error == nil { LoadingState() } }
        .searchable(text: $query)
        .navigationTitle(kind.label)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("None") { selection = [] }.disabled(selection.isEmpty)
            }
        }
        .task {
            do {
                let read = try await app.api.catalog(kind)
                let listed = Set(read.map(\.id))
                initialMissing = selection.filter { !listed.contains($0) }
                // Unticked from the start: a list naming one is refused, so it could not be saved.
                selection.removeAll { !listed.contains($0) }
                items = read
            } catch {
                self.error = error as? ZimmerError ?? .transport(error)
                items = []
            }
        }
    }

    private var needle: String { query.trimmingCharacters(in: .whitespaces).lowercased() }

    private var filtered: [CatalogItem] {
        // Available first, each group in the catalog's order.
        let catalog = items ?? []
        let all = catalog.filter { $0.unavailableReason == nil } + catalog.filter { $0.unavailableReason != nil }
        // Every word somewhere in the id, title or description, as the web's search.
        let terms = needle.split(separator: " ").map(String.init)
        guard !terms.isEmpty else { return all }
        return all.filter { item in
            let text = [item.id, item.displayTitle, item.description ?? ""].joined(separator: " ").lowercased()
            return terms.allSatisfy { text.contains($0) }
        }
    }

    /// Chosen, but not in the catalog the server lists: renamed or removed since.
    private var missing: [String] {
        guard items != nil else { return [] }
        return initialMissing.filter { needle.isEmpty || $0.lowercased().contains(needle) }
    }

    private func toggle(_ id: String) {
        Haptics.selection()
        if let index = selection.firstIndex(of: id) { selection.remove(at: index) } else { selection.append(id) }
    }
}

/// A session's model, from the models its runtime lists (`GET /api/v1/configs`), for its
/// next turn — the web UI's model editor.
struct ModelPickerSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let session: SessionSummary
    let choose: (String) async -> Bool
    @State private var models: [ModelOption]?
    @State private var error: ZimmerError?

    var body: some View {
        NavigationStack {
            List {
                if let error { ErrorBanner(error: error).listRowInsets(EdgeInsets()).listRowBackground(Color.clear) }
                ForEach(models ?? []) { model in
                    Button {
                        Task { if await choose(model.id) { dismiss() } }
                    } label: {
                        HStack {
                            Text(model.title).foregroundStyle(Theme.ink)
                            Spacer()
                            if model.id == session.model {
                                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Theme.accent)
                            }
                        }
                    }
                    .accessibilityIdentifier("model.\(model.id)")
                    .themeRows()
                }
            }
            .themeGround()
            .overlay { if models == nil && error == nil { LoadingState() } }
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task {
                do {
                    models = try await app.api.configs().models(for: session.agentRuntime ?? "claude_code")
                } catch {
                    self.error = error as? ZimmerError ?? .transport(error)
                    models = []
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Edit one kind of a session's artifacts, then save the whole list — the web UI's
/// "Modify MCP Servers / Skills / Hooks / Plugins". Takes effect on the session's next turn.
struct CatalogEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let kind: CatalogKind
    let initial: [String]
    let save: ([String]) async -> Bool
    @State private var selection: [String] = []
    @State private var saving = false

    var body: some View {
        NavigationStack {
            CatalogPicker(kind: kind, selection: $selection)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(saving ? "Saving…" : "Save") {
                            Task {
                                saving = true
                                let saved = await save(selection)
                                saving = false
                                if saved { dismiss() }
                            }
                        }
                        .disabled(saving || selection == initial)
                        .accessibilityIdentifier("catalog.save")
                    }
                }
        }
        .onAppear { selection = initial }
    }
}
