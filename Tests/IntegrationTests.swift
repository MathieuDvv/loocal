import XCTest
@testable import IslandAI

final class IntegrationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testSuggestionPrefersAppsThePersonInstalled() {
        let pick = IntegrationCenter.nextSuggestion(detected: ["messages", "github", "health"], installed: [], snoozed: [:], lastShown: nil, now: now)
        XCTAssertEqual(pick, "github")
    }

    func testSuggestionWaitsBetweenProposals() {
        let recent = now.addingTimeInterval(-3600)
        XCTAssertNil(IntegrationCenter.nextSuggestion(detected: ["github"], installed: [], snoozed: [:], lastShown: recent, now: now))
        let old = now.addingTimeInterval(-IntegrationCenter.pause - 1)
        XCTAssertEqual(IntegrationCenter.nextSuggestion(detected: ["github"], installed: [], snoozed: [:], lastShown: old, now: now), "github")
    }

    func testSuggestionSkipsConnectedAndSnoozedApps() {
        let snoozed = ["claude": now.addingTimeInterval(-86_400)]
        XCTAssertEqual(IntegrationCenter.nextSuggestion(detected: ["github", "claude", "mail"], installed: ["github"], snoozed: snoozed, lastShown: nil, now: now), "mail")
        // A month later, a dismissed app may come back.
        let long = ["claude": now.addingTimeInterval(-IntegrationCenter.snooze - 1)]
        XCTAssertEqual(IntegrationCenter.nextSuggestion(detected: ["claude"], installed: [], snoozed: long, lastShown: nil, now: now), "claude")
        XCTAssertNil(IntegrationCenter.nextSuggestion(detected: ["github"], installed: ["github"], snoozed: [:], lastShown: nil, now: now))
    }

    func testMailDraftSplitsSubject() {
        let (subject, body) = MailDraft.split("Subject: Lunch on Friday\n\nHi Sam,\nAre you free?")
        XCTAssertEqual(subject, "Lunch on Friday")
        XCTAssertEqual(body, "Hi Sam,\nAre you free?")
        XCTAssertEqual(MailDraft.split("**Subject:** Hello\nBody").subject, "Hello")
        XCTAssertEqual(MailDraft.split("Just a body").body, "Just a body")
    }

    func testGitHubRepositoryInMessage() {
        XCTAssertEqual(GitHubReader.repository(in: "what's open on apple/swift?"), "apple/swift")
        XCTAssertEqual(GitHubReader.repository(in: "see https://github.com/ml-explore/mlx-swift."), "ml-explore/mlx-swift")
        XCTAssertNil(GitHubReader.repository(in: "any new issues for me"))
    }

    @MainActor
    func testDraftLinksOpenMessagesAndMail() throws {
        let sms = try XCTUnwrap(IntegrationHub.draftLink(.messages, reply: "Running 10 min late & sorry", recipient: "+33 6 12"))
        XCTAssertTrue(sms.url.absoluteString.hasPrefix("sms:+33612&body=Running%2010%20min%20late%20%26%20sorry"), sms.url.absoluteString)
        let mail = try XCTUnwrap(IntegrationHub.draftLink(.mail, reply: "Subject: Hi\n\nSee you", recipient: "a@b.co"))
        XCTAssertEqual(mail.url.absoluteString, "mailto:a@b.co?subject=Hi&body=See%20you")
        XCTAssertEqual(Integration.with(connectorID: "int.github"), .github)
        XCTAssertEqual(IslandTint.for(connector: "int.claude"), .claude)
    }
}
