import XCTest
@testable import PDDAXReader

final class PDDVideoNetworkCaptureTests: XCTestCase {
    private let url = URL(string: "https://video3.yangkeduo.com/test/this-video.mp4")!

    func testReadsFreshVideoFromAnUnfinishedNetLog() async throws {
        let (file, handle) = try makeLog()
        defer { try? FileManager.default.removeItem(at: file) }
        try append(video(id: 1, address: "https://video3.yangkeduo.com/test/old.mp4"), to: handle)
        let capture = try PDDVideoNetworkCapture(file: file)

        try append(video(id: 2, address: url.absoluteString, destination: "image"), to: handle)
        try append(video(id: 3, address: url.absoluteString, origin: "https://example.com"), to: handle)
        try append(video(id: 4, address: url.absoluteString), to: handle)

        let result = try await capture.wait()
        XCTAssertEqual(result, url)
    }

    func testRejectsTwoDistinctVideoRequestsInTheSamePreview() async throws {
        let (file, handle) = try makeLog()
        defer { try? FileManager.default.removeItem(at: file) }
        let capture = try PDDVideoNetworkCapture(file: file)
        try append(video(id: 1, address: url.absoluteString), to: handle)
        try append(video(id: 2, address: "https://video3.yangkeduo.com/test/other.mp4"), to: handle)

        do {
            _ = try await capture.wait()
            XCTFail("Two video requests could refer to different customer messages")
        } catch PDDVideoNetworkCapture.Failure.ambiguous {}
    }

    func testPendingSecondRequestPreventsMatchingACompletedFirstRequest() async throws {
        let (file, handle) = try makeLog()
        defer { try? FileManager.default.removeItem(at: file) }
        let capture = try PDDVideoNetworkCapture(file: file)
        try append(video(id: 1, address: url.absoluteString), to: handle)
        try append(Array(video(id: 2, address: "https://video3.yangkeduo.com/test/other.mp4").prefix(2)), to: handle)

        do {
            _ = try await capture.wait()
            XCTFail("The second video must count before its response arrives")
        } catch PDDVideoNetworkCapture.Failure.ambiguous {}
    }

    func testNetworkResultTakesPriorityOverCache() async throws {
        let address = url
        let cachedAddress = address.deletingLastPathComponent().appendingPathComponent("cached.mp4")
        let result = try await PDDVideoAddressResolver.resolve(
            cacheBudget: .milliseconds(100), networkBudget: .milliseconds(100),
            cache: { cachedAddress },
            network: { address }
        )
        XCTAssertEqual(result.url, address)
        XCTAssertEqual(result.source, .network)
    }

    func testNetworkTimeoutSelectsBufferedCacheResult() async throws {
        let address = url
        let result = try await PDDVideoAddressResolver.resolve(
            cacheBudget: .milliseconds(100), networkBudget: .milliseconds(30),
            cache: { address },
            network: {
                try await Task.sleep(for: .seconds(1))
                throw PDDVideoNetworkCapture.Failure.unavailable
            }
        )
        XCTAssertEqual(result.url, address)
        XCTAssertEqual(result.source, .cache)
    }

    func testDefaultNetworkWindowAllowsAResultAfterSevenSeconds() async throws {
        let address = url
        let result = try await PDDVideoAddressResolver.resolve(
            cache: { address },
            network: {
                try await Task.sleep(for: .seconds(7))
                return address
            }
        )
        XCTAssertEqual(result.source, .network)
    }

    func testCacheStartsImmediatelyWithoutAnActiveNetworkLog() async throws {
        let address = url
        let result = try await PDDVideoAddressResolver.resolve(
            cacheBudget: .milliseconds(200),
            cache: {
                try await Task.sleep(for: .milliseconds(40))
                return address
            },
            network: nil
        )
        XCTAssertEqual(result.url, address)
        XCTAssertEqual(result.source, .cache)
    }

    func testUnresolvedNetworkAndCacheUseTheExistingAddressTimeout() async throws {
        do {
            _ = try await PDDVideoAddressResolver.resolve(
                cacheBudget: .milliseconds(10), networkBudget: .milliseconds(10),
                cache: {
                    try await Task.sleep(for: .seconds(1))
                    throw PDDCustomerVideoError.cacheUnavailable
                },
                network: { throw PDDVideoNetworkCapture.Failure.unavailable }
            )
            XCTFail("An unresolved request must reach the existing failure path")
        } catch let error as OperationTimeout {
            XCTAssertEqual(error.stage, "video-address")
        }
    }

    private func makeLog() throws -> (URL, FileHandle) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let header = """
        {"constants":{"logEventTypes":{"URL_REQUEST_START_JOB":104,"HTTP_CACHE_CALLER_REQUEST_HEADERS":57,"HTTP_TRANSACTION_READ_RESPONSE_HEADERS":125},"logSourceType":{"URL_REQUEST":1}},
        "events": [

        """
        try Data(header.utf8).write(to: file)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        return (file, handle)
    }

    private func video(id: Int, address: String, destination: String = "video",
                       origin: String = "https://mms.pinduoduo.com") -> [[String: Any]] {
        [
            ["type": 104, "phase": 1, "source": ["id": id, "type": 1],
             "params": ["url": address, "method": "GET", "initiator": origin]],
            ["type": 57, "phase": 0, "source": ["id": id, "type": 1],
             "params": ["headers": ["Sec-Fetch-Dest: \(destination)", "Range: bytes=0-"]]],
            ["type": 125, "phase": 0, "source": ["id": id, "type": 1],
             "params": ["headers": ["HTTP/1.1 206", "Content-Type: video/mp4"]]],
        ]
    }

    private func append(_ events: [[String: Any]], to handle: FileHandle) throws {
        for event in events {
            try handle.write(contentsOf: JSONSerialization.data(withJSONObject: event))
            try handle.write(contentsOf: Data(",\n".utf8))
        }
    }
}
