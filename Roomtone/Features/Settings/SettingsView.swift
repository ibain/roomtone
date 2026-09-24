import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject private var appModel: AppModel
    @State private var draft: AppSettings = .defaults

    var body: some View {
        Form {
            // Applies immediately, independent of Save.
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
                    Button("Choose…") { pickFolder() }
                }
                TextField("Sample rate", value: $draft.sampleRate, format: .number)
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
                TextField("Model", text: $draft.ai.model)
                SecureField("API Key", text: $draft.ai.apiKey)
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

            Button("Save") {
                syncModelToLanguage()
                // Don't let a stale draft undo a toolbar appearance change.
                draft.appearance = appModel.settings.appearance
                appModel.updateSettings(draft)
            }
        }
        .padding(20)
        .frame(width: 560, height: 600)
        .onAppear {
            draft = appModel.settings
            syncModelToLanguage()
        }
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
