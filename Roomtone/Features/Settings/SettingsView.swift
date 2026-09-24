import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var draft: AppSettings = .defaults
    @FocusState private var focusedField: TextFieldID?

    private enum TextFieldID { case outputDirectory, sampleRate, baseURL, model, apiKey }

    var body: some View {
        Form {
            // Applies immediately via AppModel, not through draft.
            Section("Appearance") {
                Picker("Appearance", selection: Binding(
                    get: { appModel.settings.appearance },
                    set: { appModel.setAppearance($0) }
                )) {
                    ForEach(AppearancePreference.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                Text("System follows macOS. The toolbar button sets Light or Dark directly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Recording") {
                HStack {
                    TextField("Output directory", text: $draft.outputDirectoryPath)
                        .focused($focusedField, equals: .outputDirectory)
                    Button("Choose…") { pickFolder() }
                }
                TextField("Sample rate", value: $draft.sampleRate, format: .number)
                    .focused($focusedField, equals: .sampleRate)
                Picker("Transcription language", selection: languageBinding) {
                    ForEach(WhisperLanguage.pickerOrder) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                Picker("Whisper model", selection: $draft.transcriptionModel) {
                    ForEach(availableModels) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                Text(modelHelpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("AI") {
                Picker("Provider", selection: $draft.ai.provider) {
                    ForEach(AIProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                if draft.ai.leavesMachine {
                    Label("Transcript text will leave this machine when summarizing.", systemImage: "lock.trianglebadge.exclamationmark")
                        .foregroundStyle(.orange)
                }
                TextField("Base URL", text: $draft.ai.baseURL)
                    .focused($focusedField, equals: .baseURL)
                TextField("Model", text: $draft.ai.model)
                    .focused($focusedField, equals: .model)
                SecureField("API Key", text: $draft.ai.apiKey)
                    .focused($focusedField, equals: .apiKey)
            }

            Section("Export") {
                ForEach(ExportFormat.allCases) { format in
                    Toggle(format.rawValue.uppercased(), isOn: Binding(
                        get: { draft.exportFormats.contains(format) },
                        set: { enabled in
                            if enabled {
                                if !draft.exportFormats.contains(format) {
                                    draft.exportFormats.append(format)
                                }
                            } else {
                                draft.exportFormats.removeAll { $0 == format }
                            }
                        }
                    ))
                }
            }

            Section("Privacy") {
                Toggle("Delete recordings after transcription", isOn: $draft.deleteRecordingsAfterTranscription)
                Toggle("Never upload automatically", isOn: $draft.neverUploadAutomatically)
                    .disabled(true)
            }
        }
        .padding(20)
        .frame(width: 560, height: 600)
        .onAppear {
            draft = appModel.settings
            syncModelToLanguage()
        }
        // Mac-style auto-save: controls apply on change, text fields when editing ends
        // (Return, Tab, click away), and closing the window saves whatever is left.
        .onChange(of: draft) { old, new in
            // A text field is usually focused as soon as the window opens, so check what
            // changed rather than whether one is focused.
            if focusedField == nil || !onlyTextFieldsDiffer(old, new) { save() }
        }
        .onChange(of: focusedField) { save() }
        .onSubmit { save() }
        // SwiftUI can keep the Settings view alive after close, so onDisappear isn't reliable.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            save()
        }
    }

    private func save() {
        var next = draft
        // Don't let a stale draft undo a toolbar appearance change.
        next.appearance = appModel.settings.appearance
        guard next != appModel.settings else { return }
        appModel.updateSettings(next)
    }

    private func onlyTextFieldsDiffer(_ old: AppSettings, _ new: AppSettings) -> Bool {
        var typed = old
        typed.outputDirectoryPath = new.outputDirectoryPath
        typed.sampleRate = new.sampleRate
        typed.ai.baseURL = new.ai.baseURL
        typed.ai.model = new.ai.model
        typed.ai.apiKey = new.ai.apiKey
        return typed == new
    }

    private var selectedLanguage: WhisperLanguage {
        WhisperLanguage.resolved(from: draft.transcriptionLanguage)
    }

    private var availableModels: [WhisperModel] {
        WhisperModel.models(englishOnly: selectedLanguage.prefersEnglishOnlyModel)
    }

    private var modelHelpText: String {
        if selectedLanguage.prefersEnglishOnlyModel {
            return "English-only (.en) models. Downloaded on first use — not bundled."
        }
        return "Multilingual models for this language. Downloaded on first use — not bundled."
    }

    private var languageBinding: Binding<WhisperLanguage> {
        Binding(
            get: { selectedLanguage },
            set: { newLanguage in
                draft.transcriptionLanguage = newLanguage.sidecarCode
                draft.transcriptionModel = draft.transcriptionModel.converted(
                    englishOnly: newLanguage.prefersEnglishOnlyModel
                )
            }
        )
    }

    private func syncModelToLanguage() {
        draft.transcriptionModel = draft.transcriptionModel.converted(
            englishOnly: selectedLanguage.prefersEnglishOnlyModel
        )
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            draft.outputDirectoryPath = url.path
        }
    }
}
