import Foundation
import Testing
import UserNotifications
@testable import DSHDuo

/// Fixture sealed by the Node plugin (`plugin/src/crypto.ts`) with a secret of 32 bytes of 0x07.
private let fixtureSecret = "BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc"
private let fixtureAuth = "cf39858501b8041e43558b607b6fe2e60be811ac0e919250dbba7fda349bf3c5"
private let fixtureSealed = "+Z/SLf22RqeWKcxkPXFn0K/dAKr3bv9umsNlUNJw392EcEH0phf17hHCbMC0t4dRVA=="

@MainActor
struct CryptoInteropTests {
    @Test func opensBoxesSealedByThePlugin() throws {
        let crypto = DuoCrypto(secret: try #require(Data(base64URL: fixtureSecret)))
        #expect(crypto.relayAuth == fixtureAuth)
        let data = try #require(crypto.open(fixtureSealed))
        let value = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(value["hello"]?.string == "duo")
        #expect(value["n"]?.number == 1)
    }

    @Test func roundTripsAndRejectsTampering() throws {
        let crypto = DuoCrypto(secret: Data(repeating: 9, count: 32))
        let sealed = try crypto.seal(json: ["op": "hello"])
        #expect(crypto.open(sealed) != nil)
        var raw = try #require(Data(base64Encoded: sealed))
        raw[raw.count - 1] ^= 0x01
        #expect(crypto.open(raw.base64EncodedString()) == nil)
        #expect(DuoCrypto(secret: Data(repeating: 1, count: 32)).open(sealed) == nil)
    }
}

@MainActor
struct PairingTests {
    @Test func parsesPairingLinks() throws {
        let link = "dshduo://pair?v=1&r=https%3A%2F%2Frelay.example.dev&i=room_abcdefgh&k=\(fixtureSecret)&n=Studio"
        let pairing = try #require(Pairing.parse(link, deviceId: "ios-test"))
        #expect(pairing.relay.absoluteString == "https://relay.example.dev")
        #expect(pairing.roomId == "room_abcdefgh")
        #expect(pairing.hostName == "Studio")
        #expect(pairing.crypto?.relayAuth == fixtureAuth)
    }

    @Test func rejectsForeignLinks() {
        #expect(Pairing.parse("https://example.com", deviceId: "x") == nil)
        #expect(Pairing.parse("dshduo://pair?r=https://r.dev&i=short&k=\(fixtureSecret)", deviceId: "x") == nil)
        #expect(Pairing.parse("dshduo://pair?r=https://r.dev&i=room_abcdefgh&k=abc", deviceId: "x") == nil)
    }
}

@MainActor
struct SessionModelTests {
    @Test func foldsLiveDeltasAndCommittedItems() throws {
        let model = SessionModel(id: "s")
        model.load(items: [], live: nil, hasMore: false)
        let start = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"delta":{"attemptId":"a","reset":true,"thinking":"Hm"}}"#.utf8))
        model.applyLive(start)
        let more = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"delta":{"attemptId":"a","thinking":"m.","text":"Done"}}"#.utf8))
        model.applyLive(more)
        #expect(model.live?.thinking == "Hmm.")
        #expect(model.live?.text == "Done")

        model.merge([TranscriptItem(id: "a1", kind: .text, time: 1, text: "Done")], replace: false)
        #expect(model.items.count == 1)
        model.merge([TranscriptItem(id: "a1", kind: .text, time: 1, text: "Done!")], replace: false)
        #expect(model.items.count == 1)
        #expect(model.items[0].text == "Done!")

        let end = try JSONDecoder().decode(JSONValue.self, from: Data(#"{"live":null}"#.utf8))
        model.applyLive(end)
        #expect(model.live == nil)
    }
}

@MainActor
struct MarkdownTests {
    @Test func splitsBlocks() {
        let blocks = MarkdownText.parse("# Title\n\nSome *text*.\n\n- one\n- two\n\n```swift\nlet x = 1\n```")
        #expect(blocks.count == 5)
        if case .code(let language, let code) = blocks.last {
            #expect(language == "swift")
            #expect(code == "let x = 1")
        } else {
            Issue.record("expected a code block")
        }
    }
}

@MainActor
struct NotificationPayloadTests {
    /// The Notification Service Extension path: open the sealed `e` field and rewrite the alert.
    @Test func decryptsAndRewritesAQuestionPush() throws {
        let crypto = DuoCrypto(secret: Data(repeating: 3, count: 32))
        let sealed = try crypto.seal(json: [
            "kind": "question", "sessionId": "s-1", "title": "Fix login", "body": "Open a PR?",
            "callId": "c-1", "questionId": "q1", "options": ["Yes", "No"],
        ])
        let payload = try JSONDecoder().decode(PushPayload.self, from: try #require(crypto.open(sealed)))
        let content = UNMutableNotificationContent()
        payload.apply(to: content)
        #expect(content.title == "Question · Fix login")
        #expect(content.body == "Open a PR?")
        #expect(content.subtitle == "Yes · No")
        #expect(content.categoryIdentifier == NotificationIDs.questionCategory)
        #expect(content.threadIdentifier == "s-1")
        #expect(content.userInfo[NotificationIDs.callKey] as? String == "c-1")
        #expect(content.userInfo[NotificationIDs.questionKey] as? String == "q1")
    }
}
