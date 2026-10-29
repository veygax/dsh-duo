import Foundation
import Testing
import UIKit
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

    @Test func decodesSubagentSessionsAndGoals() throws {
        let json = """
        {
          "id": "s-sub", "title": "Triage the login race", "updatedAt": 900, "running": true, "blank": false,
          "questions": 0, "parentId": "s-main",
          "subagent": { "mode": "continuable", "label": "Login triage" },
          "goal": {
            "id": "goal-1", "revision": 2, "objective": "Find the race", "phase": "active",
            "roundsStarted": 3, "maxGoalRounds": 12, "activation": "disarmed"
          }
        }
        """
        let session = try JSONDecoder().decode(SessionInfo.self, from: Data(json.utf8))
        #expect(session.isSubagent)
        #expect(session.parentId == "s-main")
        #expect(session.subagent?.mode == .continuable)
        #expect(session.goal?.objective == "Find the race")
        #expect(session.goal?.isDisarmed == true)
        #expect(session.goal?.isVisible == true)
    }
}

@MainActor
struct AttachmentModelTests {
    @Test func decodesImagesAndFilesOnAMessage() throws {
        let json = """
        {
          "id": "u1", "kind": "user", "time": 1, "text": "Look at these",
          "attachments": [
            { "kind": "image", "attachmentId": "sha256:aa", "name": "shot.png", "mediaType": "image/png",
              "bytes": 2048, "width": 800, "height": 600 },
            { "kind": "file", "attachmentId": "sha256:bb", "name": "run.log", "bytes": 90 }
          ]
        }
        """
        let item = try JSONDecoder().decode(TranscriptItem.self, from: Data(json.utf8))
        let attachments = try #require(item.attachments)
        #expect(attachments.count == 2)
        #expect(attachments[0].isImage)
        #expect(attachments[0].mediaType == "image/png")
        #expect(attachments[0].aspectRatio == 4.0 / 3.0)
        #expect(attachments[0].fileExtension == "png")
        #expect(attachments[1].kind == .file)
        #expect(attachments[1].displayName == "run.log")
        #expect(attachments[1].fileExtension == "log")
        #expect(!attachments[1].sizeText.isEmpty)
    }

    @Test func settlesAPendingMessageCarryingTheSameAttachments() throws {
        let model = SessionModel(id: "s")
        model.load(items: [], live: nil, hasMore: false)
        let pending = PendingAttachment(kind: .image, name: "a.png", bytes: 10, thumbnail: nil)
        _ = model.addPending("", steer: false, attachments: [pending], requestId: "req-queued-1")
        #expect(model.pending.count == 1)
        #expect(model.pending.first?.requestId == "req-queued-1")

        let item = TranscriptItem(id: "u1", kind: .user, time: 1, text: "", attachments: [
            TranscriptAttachment(kind: .image, attachmentId: "sha256:aa", name: "a.png",
                                 mediaType: "image/png", bytes: 10, width: 1, height: 1),
        ])
        model.merge([item], replace: false)
        #expect(model.pending.isEmpty)
    }
}

@MainActor
struct AttachmentPayloadTests {
    @Test func keepsASmallPNGAsItIs() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 40), format: format)
        let data = try #require(renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 40))
        }.pngData())
        let prepared = try #require(AttachmentPayload.image(data: data, name: "Dot"))
        #expect(prepared.kind == .image)
        #expect(prepared.mediaType == "image/png")
        #expect(prepared.data == data)
        #expect(prepared.name == "Dot.png")
        #expect(prepared.width == 80)
        #expect(prepared.height == 40)
        #expect(prepared.thumbnailData != nil)
    }

    @Test func downsamplesAndReencodesALargePhoto() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 3000, height: 2000), format: format)
        let image = renderer.image { context in
            for row in 0..<200 {
                UIColor(hue: CGFloat(row) / 200, saturation: 0.8, brightness: 0.9, alpha: 1).setFill()
                context.fill(CGRect(x: 0, y: CGFloat(row) * 10, width: 3000, height: 10))
            }
        }
        let data = try #require(image.jpegData(compressionQuality: 0.95))
        let prepared = try #require(AttachmentPayload.image(data: data, name: "IMG_0001"))
        #expect(prepared.kind == .image)
        #expect(prepared.mediaType == "image/jpeg")
        #expect(prepared.name == "IMG_0001.jpg")
        #expect((prepared.width ?? 0) <= 2048)
        #expect((prepared.height ?? 0) <= 2048)
        #expect(prepared.data.count < data.count)
        #expect(prepared.thumbnailData != nil)
    }

    @Test func keepsAGenericFileVerbatim() throws {
        let bytes = Data("hello attachment\n".utf8)
        let prepared = try #require(AttachmentPayload.file(data: bytes, name: "notes.txt"))
        #expect(prepared.kind == .file)
        #expect(prepared.mediaType == nil)
        #expect(prepared.data == bytes)
        #expect(prepared.name == "notes.txt")
    }

    @Test func cachesAttachmentBytesOnDisk() throws {
        let key = "test-\(UUID().uuidString)"
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })
        #expect(AttachmentDiskCache.store(bytes, for: key, ext: "bin") != nil)
        #expect(AttachmentDiskCache.data(for: key, ext: "bin") == bytes)
        #expect(AttachmentDiskCache.sanitized("../a/b:c\n.txt") == "..-a-b-c-.txt")
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

    @Test func turnsAnImageLineIntoAPicture() {
        let blocks = MarkdownText.parse("Before\n\n![A chart](docs/chart.png)\n\nAfter")
        #expect(blocks.count == 3)
        guard case .image(let alt, let source) = blocks[1] else {
            Issue.record("expected an image block")
            return
        }
        #expect(alt == "A chart")
        #expect(source == "docs/chart.png")
    }
}

@MainActor
struct MarkdownTableTests {
    @Test func parsesTablesWithAlignmentAndEscapedPipes() throws {
        let blocks = MarkdownText.parse("""
        Results:

        | Test | Runs | Status |
        |:-----|-----:|:------:|
        | login | 50 | ✅ |
        | a \\| b | 3 |
        After the table.
        """)
        #expect(blocks.count == 3)
        guard case .table(let table) = blocks[1] else {
            Issue.record("expected a table")
            return
        }
        #expect(table.header == ["Test", "Runs", "Status"])
        #expect(table.rows == [["login", "50", "✅"], ["a | b", "3", ""]])
        #expect(table.alignments == [.leading, .trailing, .center])
    }

    @Test func acceptsShortDelimiterCells() throws {
        let blocks = MarkdownText.parse("| Endpoint | Before | After |\n|:--|--:|:-:|\n| `GET /orders` | 1.8 s | 120 ms |")
        guard case .table(let table) = try #require(blocks.first) else {
            Issue.record("expected a table")
            return
        }
        #expect(table.alignments == [.leading, .trailing, .center])
        #expect(table.rows == [["`GET /orders`", "1.8 s", "120 ms"]])
    }

    @Test func keepsARuleUnderAPipeLineAsARule() {
        let blocks = MarkdownText.parse("a | b\n---")
        if case .table = blocks.first { Issue.record("a horizontal rule became a table") }
    }

    @Test func leavesPipesInProseAlone() {
        let blocks = MarkdownText.parse("Use a | b to pipe.\nNo table here.")
        #expect(blocks.count == 1)
        if case .table = blocks[0] { Issue.record("prose became a table") }
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
