import Foundation
import XCTest
@testable import NovelReaderApp

final class ReaderServerAPITests: XCTestCase {
    private struct Shelf: Decodable { var data: [String] }
    private struct Content: Decodable { var data: String }
    private let denied = #"{"isSuccess":false,"errorMsg":"请登录后使用","data":"NEED_LOGIN"}"#
    private let shelf = #"{"isSuccess":true,"data":["book"]}"#

    @MainActor
    func testLoginReplaysRequestAndReusesTokenForPOST() async throws {
        let fixture = ReaderAPIFixture([
            denied, #"{"isSuccess":true,"data":{"accessToken":"a+b/c="}}"#,
            shelf, #"{"isSuccess":true,"data":"正文"}"#
        ])
        let (api, connection) = makeAPI(fixture)
        let result: Shelf = try await api.request("reader3/getShelfBookWithCacheInfo", connection: connection)
        XCTAssertEqual(result.data, ["book"])
        let content: Content = try await api.request(
            "reader3/getBookContent", body: ["url": "book-url", "index": 5], connection: connection
        )
        XCTAssertEqual(content.data, "正文")
        let requests = fixture.requests
        XCTAssertEqual(requests.map { $0.url!.path }, [
            "/reader3/getShelfBookWithCacheInfo", "/reader3/login",
            "/reader3/getShelfBookWithCacheInfo", "/reader3/getBookContent"
        ])
        let login = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[1].httpBody!) as? [String: Any])
        XCTAssertEqual(login["username"] as? String, "test-user")
        XCTAssertEqual(login["password"] as? String, "test-password")
        XCTAssertEqual(login["isLogin"] as? Bool, true) // Never register an account.
        XCTAssertEqual(token(in: requests[2]), "a+b/c=")
        XCTAssertEqual(token(in: requests[3]), "a+b/c=")
        XCTAssertTrue(requests[2].url!.absoluteString.contains("%2B"))
        XCTAssertEqual(requests[3].httpMethod, "POST")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: requests[3].httpBody!) as? [String: Any])
        XCTAssertEqual(body["index"] as? Int, 5)
        XCTAssertEqual(body["url"] as? String, "book-url")
    }

    @MainActor
    func testServerWithoutLoginStillWorks() async throws {
        let fixture = ReaderAPIFixture([shelf])
        let (api, original) = makeAPI(fixture)
        var connection = original
        connection.username = ""
        connection.password = ""
        let result: Shelf = try await api.request("reader3/getShelfBookWithCacheInfo", connection: connection)
        XCTAssertEqual(result.data.count, 1)
        XCTAssertEqual(fixture.requests.count, 1)
    }

    @MainActor
    func testMissingCredentialsShowsLoginMessageInsteadOfDecodingStringAsShelf() async throws {
        let fixture = ReaderAPIFixture([denied])
        let (api, original) = makeAPI(fixture)
        var connection = original
        connection.password = ""
        do {
            let _: Shelf = try await api.request("reader3/getShelfBookWithCacheInfo", connection: connection)
            XCTFail("Expected login failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("填写账号和密码"))
        }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    @MainActor
    func testWrongPasswordShowsServerMessage() async throws {
        let fixture = ReaderAPIFixture([
            denied, #"{"isSuccess":false,"errorMsg":"密码错误","data":"NEED_LOGIN"}"#
        ])
        let (api, connection) = makeAPI(fixture)
        do {
            let _: Shelf = try await api.request("reader3/getShelfBookWithCacheInfo", connection: connection)
            XCTFail("Expected login failure")
        } catch {
            XCTAssertEqual(error.localizedDescription, "密码错误")
        }
        XCTAssertEqual(fixture.requests.count, 2)
    }

    @MainActor
    func testExpiredTokenLogsInAgainAndPreservesPOSTBody() async throws {
        let fixture = ReaderAPIFixture([
            denied, #"{"isSuccess":true,"data":{"accessToken":"old-token"}}"#, shelf,
            denied, #"{"isSuccess":true,"data":{"accessToken":"new-token"}}"#,
            #"{"isSuccess":true,"data":"正文"}"#
        ])
        let (api, connection) = makeAPI(fixture)
        let _: Shelf = try await api.request("reader3/getShelfBookWithCacheInfo", connection: connection)
        let _: Content = try await api.request(
            "reader3/getBookContent", body: ["url": "book-url", "index": 7], connection: connection
        )
        let requests = fixture.requests
        XCTAssertEqual(requests.count, 6)
        XCTAssertEqual(token(in: requests[3]), "old-token")
        XCTAssertEqual(token(in: requests[5]), "new-token")
        XCTAssertEqual(requests[3].httpBody, requests[5].httpBody)
    }

    @MainActor
    func testLoginRetryIsBounded() async throws {
        let fixture = ReaderAPIFixture([
            denied, #"{"isSuccess":true,"data":{"accessToken":"rejected-token"}}"#, denied
        ])
        let (api, connection) = makeAPI(fixture)
        do {
            let _: Shelf = try await api.request("reader3/getShelfBookWithCacheInfo", connection: connection)
            XCTFail("Expected expired login failure")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("登录已失效"))
        }
        XCTAssertEqual(fixture.requests.count, 3)
    }

    @MainActor
    func testChangedCredentialsDoNotReusePreviousToken() async throws {
        let fixture = ReaderAPIFixture([
            denied, #"{"isSuccess":true,"data":{"accessToken":"first-token"}}"#, shelf,
            denied, #"{"isSuccess":true,"data":{"accessToken":"second-token"}}"#, shelf
        ])
        let (api, original) = makeAPI(fixture)
        let _: Shelf = try await api.request("reader3/getShelfBookWithCacheInfo", connection: original)
        var changed = original
        changed.password = "changed-password"
        let _: Shelf = try await api.request("reader3/getShelfBookWithCacheInfo", connection: changed)
        XCTAssertNil(token(in: fixture.requests[3]))
        XCTAssertEqual(token(in: fixture.requests[5]), "second-token")
    }

    @MainActor
    private func makeAPI(_ fixture: ReaderAPIFixture) -> (ReaderServerAPI, NASConnection) {
        let host = UUID().uuidString.lowercased() + ".test"
        ReaderAPIURLProtocol.register(fixture, host: host)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ReaderAPIURLProtocol.self]
        let connection = NASConnection(
            name: "Test", kind: .readerServer, baseURL: URL(string: "http://\(host)")!,
            username: "test-user", password: "test-password", isEnabled: true
        )
        return (ReaderServerAPI(session: URLSession(configuration: config)), connection)
    }

    private func token(in request: URLRequest) -> String? {
        URLComponents(url: request.url!, resolvingAgainstBaseURL: true)?
            .queryItems?.first { $0.name == "accessToken" }?.value
    }
}

private final class ReaderAPIFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [String]
    private var recorded: [URLRequest] = []

    init(_ responses: [String]) { self.responses = responses }

    var requests: [URLRequest] { lock.withLock { recorded } }

    func respond(to request: URLRequest) throws -> Data {
        try lock.withLock {
            var request = request
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var body = Data()
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
                request.httpBody = body
            }
            recorded.append(request)
            guard !responses.isEmpty else { throw URLError(.badServerResponse) }
            return Data(responses.removeFirst().utf8)
        }
    }
}

private final class ReaderAPIURLProtocol: URLProtocol, @unchecked Sendable {
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var fixtures: [String: ReaderAPIFixture] = [:]
    }
    private static let registry = Registry()

    static func register(_ fixture: ReaderAPIFixture, host: String) {
        registry.lock.withLock { registry.fixtures[host] = fixture }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        do {
            let fixture = Self.registry.lock.withLock { Self.registry.fixtures[request.url!.host!] }
            let data = try XCTUnwrap(fixture).respond(to: request)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
}
