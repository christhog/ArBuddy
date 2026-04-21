//
//  ToolCall.swift
//  ARBuddy
//
//  Created by Claude on 12.04.26.
//

import Foundation
import Combine

// MARK: - Tool Definition

/// Definition of a tool that the LLM can call
struct ToolDefinition: Codable, Equatable {
    let name: String
    let description: String
    let parameters: [ToolParameter]

    /// Formats the tool for the system prompt
    var promptDescription: String {
        var desc = "- \(name): \(description)"
        if !parameters.isEmpty {
            let params = parameters.map { "\($0.name): \($0.type)" }.joined(separator: ", ")
            desc += " (\(params))"
        }
        return desc
    }
}

/// Parameter definition for a tool
struct ToolParameter: Codable, Equatable {
    let name: String
    let type: String
    let description: String
    let required: Bool
    let defaultValue: String?

    init(name: String, type: String, description: String, required: Bool = true, defaultValue: String? = nil) {
        self.name = name
        self.type = type
        self.description = description
        self.required = required
        self.defaultValue = defaultValue
    }
}

// MARK: - Tool Call

/// Parsed tool call from LLM output
struct ToolCall: Codable, Equatable {
    let name: String
    let parameters: [String: String]

    /// Parses a tool call from JSON text
    static func parse(from text: String) -> ToolCall? {
        // Look for <tool_call>...</tool_call> pattern
        guard let startRange = text.range(of: "<tool_call>"),
              let endRange = text.range(of: "</tool_call>") else {
            return nil
        }

        let jsonText = String(text[startRange.upperBound..<endRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = jsonText.data(using: .utf8) else {
            return nil
        }

        do {
            let decoded = try JSONDecoder().decode(ToolCallJSON.self, from: data)
            return ToolCall(name: decoded.name, parameters: decoded.parameters ?? [:])
        } catch {
            print("[ToolCall] Failed to parse: \(error)")
            return nil
        }
    }

    /// Checks if a text contains a tool call
    static func containsToolCall(_ text: String) -> Bool {
        text.contains("<tool_call>") && text.contains("</tool_call>")
    }

    /// Extracts text before and after a tool call
    static func extractTextParts(from text: String) -> (before: String, after: String) {
        guard let startRange = text.range(of: "<tool_call>"),
              let endRange = text.range(of: "</tool_call>") else {
            return (text, "")
        }

        let before = String(text[..<startRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let after = String(text[endRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (before, after)
    }
}

/// JSON structure for tool call parsing
private struct ToolCallJSON: Codable {
    let name: String
    let parameters: [String: String]?
}

// MARK: - Available Tools

/// Available tools for the buddy to use
enum BuddyTool: String, CaseIterable {
    case getUserInfo = "get_user_info"
    case getNearbyPlaces = "get_nearby_places"
    case getRecentTalks = "get_recent_talks"
    case queryCloudAI = "query_cloud_ai"

    var definition: ToolDefinition {
        switch self {
        case .getUserInfo:
            return ToolDefinition(
                name: rawValue,
                description: "Gibt Informationen über den Benutzer zurück (Level, XP, besuchte Orte)",
                parameters: []
            )
        case .getNearbyPlaces:
            return ToolDefinition(
                name: rawValue,
                description: "Findet interessante Orte in der Nähe des Benutzers",
                parameters: [
                    ToolParameter(name: "radius", type: "number", description: "Suchradius in Metern", required: false, defaultValue: "500")
                ]
            )
        case .getRecentTalks:
            return ToolDefinition(
                name: rawValue,
                description: "Gibt die letzten Chat-Nachrichten zurück",
                parameters: [
                    ToolParameter(name: "limit", type: "number", description: "Anzahl der Nachrichten", required: false, defaultValue: "5")
                ]
            )
        case .queryCloudAI:
            return ToolDefinition(
                name: rawValue,
                description: "Stellt eine komplexe Frage an die Cloud-KI für detaillierte Antworten",
                parameters: [
                    ToolParameter(name: "query", type: "string", description: "Die Frage an die Cloud-KI", required: true)
                ]
            )
        }
    }

    static var allDefinitions: [ToolDefinition] {
        allCases.map { $0.definition }
    }
}

// MARK: - Buddy System Prompt

/// System prompt builder for the buddy character
struct BuddySystemPrompt {
    let buddyName: String
    let personality: String
    let tools: [ToolDefinition]
    let enableTools: Bool

    init(
        buddyName: String = "Jona",
        personality: String = "freundlich und hilfsbereit",
        tools: [ToolDefinition] = BuddyTool.allDefinitions,
        enableTools: Bool = true
    ) {
        self.buddyName = buddyName
        self.personality = personality
        self.tools = tools
        self.enableTools = enableTools
    }

    /// Simple prompt for small models (no tool support)
    var simplePrompt: String {
        """
        Du bist \(buddyName), ein freundlicher AR-Begleiter.
        Antworte kurz auf Deutsch (1-2 Sätze).
        Sei hilfsbereit und freundlich.

        \(Self.emotionMarkerInstructions)
        """
    }

    /// Shared instructions appended to every prompt — tells Claude how to emit
    /// inline emotion markers so the buddy's face can change mid-response.
    static let emotionMarkerInstructions: String = """
    ## Emotions-Marker (WICHTIG)
    Setze in deine Antworten Emotions-Marker in eckigen Klammern, damit dein Gesicht passend animiert wird. Wechsle die Emotion so oft es sich natürlich anfühlt — mindestens am Satzanfang, gern auch innerhalb eines Satzes.

    Verfügbare Marker (genau so schreiben):
    [emotion:happy] [emotion:laughter] [emotion:sad] [emotion:melancholy] [emotion:angry] [emotion:surprised] [emotion:fear] [emotion:disgust] [emotion:thinking] [emotion:skeptical] [emotion:wonder] [emotion:neutral]

    Regeln:
    - Platziere den Marker direkt VOR dem Text, der in dieser Emotion gesagt werden soll.
    - Kehre am Ende von emotionalen Passagen mit [emotion:neutral] zum Normalzustand zurück.
    - Die Marker werden aus dem gesprochenen Text entfernt — schreib sie nur als Steuertags, nicht als Teil deines Satzes.

    Beispiel:
    [emotion:happy] Hey, schön dich zu sehen! [emotion:thinking] Hmm, das ist eine gute Frage. [emotion:surprised] Oh wow, das hätte ich nicht gedacht! [emotion:neutral] Lass mich kurz nachschauen.

    ## Gesten-Marker
    Du kannst zusätzlich maximal eine Körperbewegung pro Antwort triggern. Setze den Marker ganz an den Anfang der Antwort — er feuert, sobald du zu sprechen beginnst.

    Kurze prozedurale Gesten (überlappen mit Sprache, ~0.5–1s):
    [gesture:nod] (Zustimmen), [gesture:shake] (Verneinen), [gesture:jump] (Freude / Aufregung), [gesture:cheer] (Feiern), [gesture:bow] (Begrüßen / Dank), [gesture:wiggle] (verspielt), [gesture:lookLeft], [gesture:lookRight]

    Längere Ganzkörper-Animationen (ca. 1–3s, nutze sie wenn der Ausdruck es rechtfertigt):
    [gesture:wave] (Winken / Hallo), [gesture:blowKiss] (Kusshand), [gesture:yesJump] (freudiger Sprung), [gesture:thinking] (nachdenkliche Pose), [gesture:dontKnow] (Schulterzucken / keine Ahnung), [gesture:shy] (schüchtern), [gesture:pointLeft], [gesture:pointUp], [gesture:pointDown], [gesture:frustration] (genervt), [gesture:crossedArms] (Arme verschränkt), [gesture:awake] (aufwachen / aufmerksam werden)

    Nutze Gesten sparsam — nur wenn sie den Ausdruck wirklich unterstützen. Maximal eine Geste pro Antwort. Bei normalen Antworten keinen Gesten-Marker setzen.
    """

    /// Builds the full system prompt
    var prompt: String {
        // Use simple prompt if tools are disabled
        guard enableTools else {
            return simplePrompt
        }

        var lines: [String] = []

        // Character description
        lines.append("Du bist \(buddyName), ein \(personality)er AR-Begleiter in der ARBuddy App.")
        lines.append("Du hilfst dem Benutzer dabei, interessante Orte zu entdecken und Quests zu absolvieren.")
        lines.append("")

        // Response guidelines
        lines.append("## Richtlinien")
        lines.append("- Antworte auf Deutsch")
        lines.append("- Halte deine Antworten kurz (max 2-3 Sätze)")
        lines.append("- Bleib in deiner Rolle als freundlicher Buddy")
        lines.append("- Verwende einen lockeren, aber respektvollen Ton")
        lines.append("")

        // Tool usage
        if !tools.isEmpty {
            lines.append("## Verfügbare Tools")
            lines.append("Du kannst folgende Tools verwenden, um Informationen abzurufen:")
            for tool in tools {
                lines.append(tool.promptDescription)
            }
            lines.append("")
            lines.append("Um ein Tool zu verwenden, antworte mit:")
            lines.append("<tool_call>{\"name\": \"tool_name\", \"parameters\": {...}}</tool_call>")
            lines.append("")
            lines.append("Verwende Tools nur wenn nötig. Für einfache Fragen antworte direkt.")
            lines.append("")
        }

        lines.append(Self.emotionMarkerInstructions)

        return lines.joined(separator: "\n")
    }

    /// Creates a prompt for a specific buddy
    static func forBuddy(_ buddy: Buddy, enableTools: Bool = true) -> BuddySystemPrompt {
        BuddySystemPrompt(
            buddyName: buddy.name,
            personality: buddy.description ?? "freundlich und hilfsbereit",
            enableTools: enableTools
        )
    }

    /// Creates a simple prompt for small models
    static func simpleForBuddy(_ buddy: Buddy) -> BuddySystemPrompt {
        BuddySystemPrompt(
            buddyName: buddy.name,
            personality: buddy.description ?? "freundlich und hilfsbereit",
            tools: [],
            enableTools: false
        )
    }
}

// MARK: - Convenience Extensions

extension String {
    /// Extracts tool calls from the string
    var toolCalls: [ToolCall] {
        var calls: [ToolCall] = []
        var remaining = self

        while let startRange = remaining.range(of: "<tool_call>"),
              let endRange = remaining.range(of: "</tool_call>") {

            let fullRange = startRange.lowerBound..<endRange.upperBound
            let callText = String(remaining[fullRange])

            if let call = ToolCall.parse(from: callText) {
                calls.append(call)
            }

            remaining = String(remaining[endRange.upperBound...])
        }

        return calls
    }

    /// Removes tool call tags from the string
    var withoutToolCalls: String {
        var result = self
        while let startRange = result.range(of: "<tool_call>"),
              let endRange = result.range(of: "</tool_call>") {
            let fullRange = startRange.lowerBound..<endRange.upperBound
            result.removeSubrange(fullRange)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes `[emotion:xxx]` markers from the string (for UI display & TTS
    /// fallback paths that don't consume the markers themselves).
    var withoutEmotionMarkers: String {
        let pattern = #"\[emotion:[a-zA-Z]+\]"#
        return self.replacingOccurrences(of: pattern, with: "",
                                         options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes `[gesture:xxx]` markers from the string.
    var withoutGestureMarkers: String {
        let pattern = #"\[gesture:[a-zA-Z]+\]"#
        return self.replacingOccurrences(of: pattern, with: "",
                                         options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns the first `[gesture:xxx]` marker name (lowercased), if any.
    /// We only support one gesture per response — mirrors the LLM instruction.
    var firstGestureMarker: String? {
        let pattern = #"\[gesture:([a-zA-Z]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: self,
                                           range: NSRange(location: 0, length: (self as NSString).length)),
              match.numberOfRanges > 1
        else { return nil }
        return (self as NSString).substring(with: match.range(at: 1)).lowercased()
    }

    /// Splits the string at `[emotion:xxx]` markers into ordered
    /// `(text, emotion)` segments. Emotion is the marker preceding the text;
    /// the leading chunk before the first marker has `emotion == nil`.
    /// Empty text chunks are preserved so bookmark timing stays stable.
    var emotionSegments: [(text: String, emotion: String?)] {
        let pattern = #"\[emotion:([a-zA-Z]+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [(self, nil)]
        }
        let ns = self as NSString
        let matches = regex.matches(in: self, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return [(self, nil)] }

        var segments: [(String, String?)] = []
        var cursor = 0
        var pendingEmotion: String? = nil

        for match in matches {
            let markerStart = match.range.location
            let markerEnd = markerStart + match.range.length
            if markerStart > cursor {
                let chunk = ns.substring(with: NSRange(location: cursor, length: markerStart - cursor))
                segments.append((chunk, pendingEmotion))
            }
            pendingEmotion = ns.substring(with: match.range(at: 1))
            cursor = markerEnd
        }
        if cursor < ns.length {
            segments.append((ns.substring(from: cursor), pendingEmotion))
        }
        return segments
    }
}
