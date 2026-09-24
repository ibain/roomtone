import Foundation

/// Provider-agnostic summarization. Uses chunk → summarize → merge for long transcripts.
final class ProviderSummarizer: Summarizing {
    private let session: URLSession
    private let maxChunkChars = 12_000

    init(session: URLSession = .shared) {
        self.session = session
    }

    func generateSummary(transcript: Transcript, options: SummaryOptions) async throws -> MeetingSummary {
        guard options.provider != .none else {
            throw SummaryError.providerDisabled
        }

        let plain = transcript.blocks.map { block in
            "[\(Self.timestamp(block.start))] \(block.speaker): \(block.text)"
        }.joined(separator: "\n")

        let chunks = Self.chunk(plain, maxChars: maxChunkChars)
        var partials: [String] = []
        for (idx, chunk) in chunks.enumerated() {
            let prompt = """
            Summarize this meeting transcript chunk (\(idx + 1)/\(chunks.count)).
            Focus on decisions, action items, risks, open questions, follow-ups.
            Transcript chunk:
            \(chunk)
            """
            let text = try await complete(prompt: prompt, options: options)
            partials.append(text)
        }

        let mergePrompt = """
        Merge these chunk summaries into one meeting summary with exactly these markdown sections:
        # Overview
        # Key Decisions
        # Action Items
        # Risks
        # Open Questions
        # Follow-ups
        # Attendees

        Use bullet lists where appropriate. If unknown, write "None".

        Chunk summaries:
        \(partials.joined(separator: "\n\n---\n\n"))
        """
        let markdown = try await complete(prompt: mergePrompt, options: options)
        return Self.parse(markdown: markdown, provider: options.provider.rawValue)
    }

    private func complete(prompt: String, options: SummaryOptions) async throws -> String {
        let base: String
        switch options.provider {
        case .openAI:
            base = options.baseURL.isEmpty ? "https://api.openai.com/v1" : options.baseURL
        case .localCompatible:
            base = options.baseURL.isEmpty ? "http://127.0.0.1:11434/v1" : options.baseURL
        case .none:
            throw SummaryError.providerDisabled
        }

        guard let url = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions") else {
            throw SummaryError.badURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !options.apiKey.isEmpty {
            request.setValue("Bearer \(options.apiKey)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = [
            "model": options.model,
            "temperature": 0.2,
            "messages": [
                ["role": "system", "content": "You are a precise meeting notes assistant. Never invent facts."],
                ["role": "user", "content": prompt]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw SummaryError.http(text)
        }
        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let content = decoded.choices.first?.message.content else {
            throw SummaryError.empty
        }
        return content
    }

    private static func chunk(_ text: String, maxChars: Int) -> [String] {
        guard text.count > maxChars else { return [text] }
        var result: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: maxChars, limitedBy: text.endIndex) ?? text.endIndex
            var sliceEnd = end
            if end < text.endIndex, let newline = text[start..<end].lastIndex(of: "\n") {
                sliceEnd = newline
            }
            result.append(String(text[start..<sliceEnd]))
            start = sliceEnd
            if start < text.endIndex, text[start] == "\n" {
                start = text.index(after: start)
            }
        }
        return result.filter { !$0.isEmpty }
    }

    private static func parse(markdown: String, provider: String) -> MeetingSummary {
        func section(_ name: String) -> String {
            return extractSection(named: name, from: markdown)
        }
        func bullets(_ text: String) -> [String] {
            text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix("-") || $0.hasPrefix("*") }
                .map { $0.drop(while: { $0 == "-" || $0 == "*" || $0 == " " }) }
                .map(String.init)
                .filter { !$0.isEmpty && $0.lowercased() != "none" }
        }

        let overview = section("Overview")
        return MeetingSummary(
            overview: overview.trimmingCharacters(in: .whitespacesAndNewlines),
            keyDecisions: bullets(section("Key Decisions")),
            actionItems: bullets(section("Action Items")),
            risks: bullets(section("Risks")),
            openQuestions: bullets(section("Open Questions")),
            followUps: bullets(section("Follow-ups")),
            attendees: bullets(section("Attendees")),
            markdown: markdown,
            provider: provider
        )
    }

    private static func extractSection(named name: String, from markdown: String) -> String {
        let lines = markdown.components(separatedBy: .newlines)
        var capturing = false
        var collected: [String] = []
        for line in lines {
            if line.hasPrefix("#") {
                let heading = line.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased()
                if capturing { break }
                capturing = heading == name.lowercased()
                continue
            }
            if capturing { collected.append(line) }
        }
        return collected.joined(separator: "\n")
    }

    private static func timestamp(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }

    enum SummaryError: LocalizedError {
        case providerDisabled
        case badURL
        case http(String)
        case empty
        var errorDescription: String? {
            switch self {
            case .providerDisabled: return "AI provider is set to None"
            case .badURL: return "Invalid AI base URL"
            case .http(let m): return "AI request failed: \(m)"
            case .empty: return "AI returned empty summary"
            }
        }
    }
}

private struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { var content: String? }
        var message: Message
    }
    var choices: [Choice]
}
