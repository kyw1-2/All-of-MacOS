import AppKit
import XCTest
@testable import AllOfMacOS

/// 7.0 "Craft & Fluidity": native AI beside the CLI agents, the launcher's
/// pieces and the recipe view.
final class AOM70AITests: XCTestCase {
    func testAnthropicStreamEvents() {
        // Shapes from the Messages API stream (event: … / data: …).
        XCTAssertEqual(AOMAISSE.payload("data: {\"type\":\"ping\"}"), "{\"type\":\"ping\"}")
        XCTAssertNil(AOMAISSE.payload("event: content_block_delta"))
        XCTAssertNil(AOMAISSE.payload(""))
        XCTAssertEqual(AOMAISSE.anthropic(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}"#), .text("Hi"))
        XCTAssertEqual(AOMAISSE.anthropic(#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"…"}}"#), .thinking)
        XCTAssertEqual(AOMAISSE.anthropic(#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#), .thinking)
        XCTAssertEqual(AOMAISSE.anthropic(#"{"type":"message_delta","delta":{"stop_reason":"refusal"},"usage":{}}"#), .stop("refusal"))
        XCTAssertEqual(AOMAISSE.anthropic(#"{"type":"message_stop"}"#), .done)
        XCTAssertEqual(AOMAISSE.anthropic(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#), .error("Overloaded"))
        XCTAssertEqual(AOMAISSE.anthropic("not json"), .none)
        XCTAssertEqual(AOMAISSE.stopNotice("refusal"), "The model declined to answer this.")
        XCTAssertNil(AOMAISSE.stopNotice("end_turn"))
    }

    func testOpenAICompatibleStreamEvents() {
        XCTAssertEqual(AOMAISSE.openAI(#"{"choices":[{"index":0,"delta":{"content":"Hel"}}]}"#), .text("Hel"))
        XCTAssertEqual(AOMAISSE.openAI(#"{"choices":[{"index":0,"delta":{"reasoning_content":"hm"}}]}"#), .thinking)
        XCTAssertEqual(AOMAISSE.openAI(#"{"choices":[{"index":0,"delta":{},"finish_reason":"length"}]}"#), .stop("length"))
        XCTAssertEqual(AOMAISSE.openAI("[DONE]"), .done)
        XCTAssertEqual(AOMAISSE.openAI(#"{"error":{"message":"Invalid key"}}"#), .error("Invalid key"))
        XCTAssertEqual(AOMAISSE.errorMessage(#"{"error":{"type":"x","message":"model not found"}}"#, status: 404), "model not found")
        XCTAssertTrue(AOMAISSE.errorMessage("", status: 401).contains("401"))
    }

    func testAnthropicBodyUsesEffortAndFallbacksOnlyWhereSupported() {
        let turns = [AOMAITurn(role: .user, text: "Hi")]
        let opus = AOMAIClient.anthropicBody(model: "claude-opus-5-5", system: "S", turns: turns, effort: .low, firstParty: true)
        XCTAssertEqual((opus.body["output_config"] as? [String: String])?["effort"], "low")
        XCTAssertEqual(opus.body["fallbacks"] as? String, "default")
        XCTAssertEqual(opus.betas, ["server-side-fallback-2026-07-01"])
        XCTAssertEqual(opus.body["stream"] as? Bool, true)
        XCTAssertNil(opus.body["temperature"], "sampling parameters are rejected on the 2026-10-21 API")
        let haiku = AOMAIClient.anthropicBody(model: "claude-haiku-5-5", system: "S", turns: turns, effort: .medium, firstParty: true)
        XCTAssertNotNil(haiku.body["output_config"])
        XCTAssertNil(haiku.body["fallbacks"], "Haiku has no server-side fallback")
        let proxy = AOMAIClient.anthropicBody(model: "claude-haiku-5-5", system: "S", turns: turns, effort: .low, firstParty: false)
        XCTAssertNil(proxy.body["output_config"], "a local router gets the plain request")
        XCTAssertTrue(proxy.betas.isEmpty)
        let old = AOMAIClient.anthropicBody(model: "claude-sonnet-4-5", system: "S", turns: turns, effort: .low, firstParty: true)
        XCTAssertNil(old.body["output_config"])
        let messages = opus.body["messages"] as? [[String: String]]
        XCTAssertEqual(messages?.first?["role"], "user")
        XCTAssertEqual(AOMAIClient.endpoint("http://127.0.0.1:8082/", "/v1/messages")?.absoluteString, "http://127.0.0.1:8082/v1/messages")
    }

    func testOpenAIBodyLeadsWithTheSystemMessage() {
        let body = AOMAIClient.openAIBody(model: "deepseek-chat", system: "S", turns: [AOMAITurn(role: .user, text: "Q")])
        let messages = body["messages"] as? [[String: String]]
        XCTAssertEqual(messages?.map { $0["role"] ?? "" }, ["system", "user"])
    }

    func testModelRefsAndListedModels() {
        XCTAssertEqual(AOMAIModelRef(key: "anthropic:claude-opus-5-5"), AOMAIModelRef(provider: .anthropic, model: "claude-opus-5-5"))
        XCTAssertEqual(AOMAIModelRef(key: "ollama:llama3.2:3b")?.model, "llama3.2:3b", "model names may contain colons")
        XCTAssertNil(AOMAIModelRef(key: "nope:x"))
        XCTAssertNil(AOMAIModelRef(key: "apple:"))
        let data = Data(#"{"data":[{"id":"gpt-5","object":"model"},{"id":"text-embedding-3-small"},{"id":"claude-opus-5-5","display_name":"Claude Opus 5.5"}]}"#.utf8)
        let models = AOMAIClient.parseModels(data, provider: .openAI)
        XCTAssertEqual(models.map(\.id), ["gpt-5", "claude-opus-5-5"])
        XCTAssertEqual(models.last?.title, "Claude Opus 5.5")
    }

    func testCLIAgentsStayBesideTheModels() {
        XCTAssertTrue(AOMAIProvider.claudeCode.isAgent)
        XCTAssertTrue(AOMAIProvider.codex.isAgent)
        XCTAssertFalse(AOMAIProvider.claudeCode.suggestedModels.isEmpty)
        XCTAssertTrue(AOMAIProvider.localProxy.isAnthropicCompatible)
        XCTAssertFalse(AOMAIProvider.localProxy.needsKey, "the :8082 router needs no key")
        XCTAssertEqual(AOMAIProvider.localProxy.defaultBaseURL, "http://127.0.0.1:8082")
    }

    func testShellEnvironmentParsing() {
        let parsed = AOMAIConfig.parseEnvironment("OPENAI_API_KEY=sk-1\0ANTHROPIC_API_KEY=\0OPENAI_BASE_URL=https://x/v1\0junk\0")
        XCTAssertEqual(parsed, ["OPENAI_API_KEY": "sk-1", "OPENAI_BASE_URL": "https://x/v1"])
        XCTAssertEqual(AOMAIKeychain.masked("sk-abcdefgh1234"), "sk-…1234")
        XCTAssertEqual(AOMAIKeychain.masked("short"), "•••••")
    }

    func testTurnsAlternateAndStartWithTheUser() {
        let turns = PaletteAIChat.alternating([
            AOMAITurn(role: .assistant, text: "stray"), AOMAITurn(role: .user, text: "a"),
            AOMAITurn(role: .user, text: "b"), AOMAITurn(role: .assistant, text: "c"),
        ])
        XCTAssertEqual(turns, [AOMAITurn(role: .user, text: "a\n\nb"), AOMAITurn(role: .assistant, text: "c")])
    }

    func testOnDevicePromptFoldsRecentTurns() {
        XCTAssertEqual(AOMAppleIntelligence.prompt([AOMAITurn(role: .user, text: "Hi")]), "Hi")
        let prompt = AOMAppleIntelligence.prompt([AOMAITurn(role: .user, text: "Q1"), AOMAITurn(role: .assistant, text: "A1"),
                                                  AOMAITurn(role: .user, text: "Q2")])
        XCTAssertTrue(prompt.contains("User: Q1"))
        XCTAssertTrue(prompt.hasSuffix("User: Q2"))
    }

    func testWarmClaudeCodeSessionArguments() {
        let args = PaletteAgentSession.arguments(model: "sonnet", system: "Be brief.", resume: "abc")
        XCTAssertTrue(zip(args, args.dropFirst()).contains { $0 == ("--input-format", "stream-json") }, "questions arrive on stdin")
        XCTAssertTrue(zip(args, args.dropFirst()).contains { $0 == ("--permission-mode", "plan") }, "read-only in the launcher")
        XCTAssertTrue(args.contains("--strict-mcp-config"))
        XCTAssertTrue(zip(args, args.dropFirst()).contains { $0 == ("--model", "sonnet") })
        XCTAssertEqual(args.suffix(2), ["--resume", "abc"])
        XCTAssertFalse(PaletteAgentSession.arguments(model: "default", system: "", resume: nil).contains("--model"))
        XCTAssertFalse(args.contains { $0.contains("dangerously") })
        let line = PaletteAgentSession.inputLine("안녕")
        XCTAssertEqual(line.last, 0x0A)
        let object = try? JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, "user")
    }
}

final class AOM70LauncherTests: XCTestCase {
    func testMarkdownBlocks() {
        let text = """
        # Title
        Some **bold** text
        continues here.

        - one
        - two
        1. first
        2. second
        > quoted

        | A | B |
        |---|:-:|
        | 1 | 2 |
        ```swift
        let x = 1
        ```
        ---
        ```bash
        echo streaming
        """
        let blocks = AOMMarkdown.parse(text)
        XCTAssertEqual(blocks[0], .heading(level: 1, text: "Title"))
        XCTAssertEqual(blocks[1], .paragraph("Some **bold** text\ncontinues here."))
        XCTAssertEqual(blocks[2], .list(ordered: false, items: ["one", "two"]))
        XCTAssertEqual(blocks[3], .list(ordered: true, items: ["first", "second"]))
        XCTAssertEqual(blocks[4], .quote("quoted"))
        XCTAssertEqual(blocks[5], .table(rows: [["A", "B"], ["1", "2"]]), "the separator row is dropped")
        XCTAssertEqual(blocks[6], .code(language: "swift", text: "let x = 1"))
        XCTAssertEqual(blocks[7], .rule)
        XCTAssertEqual(blocks[8], .code(language: "bash", text: "echo streaming"), "an open fence runs to the end while streaming")
        XCTAssertEqual(AOMMarkdown.parse("#hashtag"), [.paragraph("#hashtag")])
    }

    func testWindowLayoutPreviewTargets() {
        XCTAssertEqual(AOMLauncherWindowDetail.target(for: "window.left"), CGRect(x: 0, y: 0, width: 0.5, height: 1))
        XCTAssertEqual(AOMLauncherWindowDetail.target(for: "window.bottomRight"), CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
        XCTAssertEqual(AOMLauncherWindowDetail.target(for: "window.rightTwoThirds")?.width ?? 0, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertNil(AOMLauncherWindowDetail.target(for: "window.pinFront"))
    }

    func testClipDetailSpotsCode() {
        XCTAssertTrue(AOMLauncherClipDetail.looksLikeCode("func a() {\n    return 1\n}"))
        XCTAssertFalse(AOMLauncherClipDetail.looksLikeCode("Dear team,\nThanks for the notes."))
        XCTAssertFalse(AOMLauncherClipDetail.looksLikeCode("one line"))
    }

    func testModelPickerRouteIsSearchable() {
        XCTAssertEqual(PaletteRoute.aiModels.title, "Choose Model")
        XCTAssertTrue(PaletteRoute.aiModels.isSearchable)
        XCTAssertEqual(PaletteRoute.ai.placeholder, "Ask anything…")
    }

    func testLauncherInkIsDarkerThanTheSystemTertiaryLabel() {
        // Launcher text over glass (7.0): the tertiary ink stays readable.
        let ink = NSColor(AOMCraftColor.inkTertiary)
        let resolved = NSAppearance(named: .aqua).map { appearance -> NSColor in
            var color = ink
            appearance.performAsCurrentDrawingAppearance { color = ink.usingColorSpace(.sRGB) ?? ink }
            return color
        }
        XCTAssertGreaterThanOrEqual(resolved?.alphaComponent ?? 0, 0.45)
    }
}

final class AOM70AutomationTests: XCTestCase {
    func testRecipeStepsNestBranchesAndCarryTheLastRun() {
        var branch = TriggerAction(actionType: .ifElse)
        branch.parameters.children = [TriggerAction(actionType: .maximizeWindow)]
        branch.parameters.elseChildren = [TriggerAction(actionType: .snapWindowLeft)]
        var off = TriggerAction(actionType: .snapWindowRight)
        off.isEnabled = false
        let steps = ModernGesturesWorkspace.recipeSteps([TriggerAction(actionType: .maximizeWindow), branch, off],
                                                        runState: .succeeded(Date()))
        XCTAssertEqual(steps.map(\.index), [1, 2, 5])
        XCTAssertTrue(steps[1].isBranchContainer)
        XCTAssertEqual(steps[1].thenChildren.map(\.index), [3])
        XCTAssertEqual(steps[1].elseChildren.map(\.index), [4])
        XCTAssertEqual(steps[0].runStatus, .succeeded)
        XCTAssertEqual(steps[2].runStatus, .idle, "a step that is off didn't run")
        XCTAssertEqual(steps[2].subtitle, "Off")
    }
}
