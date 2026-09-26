import XCTest
@testable import Nursery

/// The move from the go2rtc server to the camera read directly: the camera address from go2rtc.
final class MigrationTests: XCTestCase {
    private let expected = ServerMigration.Result(host: "192.168.0.197", port: 554, user: "u@x", password: "p:ss",
                                                  mainPath: "stream1", smallPath: "stream2", brand: .tapo)

    func testStreamsJSON() {
        let json = #"""
        {"nursery":{"producers":[{"url":"rtsp://u%40x:p%3Ass@192.168.0.197:554/stream1"}],"consumers":null},
         "nursery_sd":{"producers":[{"url":"rtsp://u%40x:p%3Ass@192.168.0.197:554/stream2"}]},
         "kitchen":{"producers":[{"url":"rtsp://a:b@192.168.0.50:554/live"}]}}
        """#
        let r = ServerMigration.parse(streamsJSON: Data(json.utf8), main: "nursery", small: "nursery_sd")
        XCTAssertEqual(r, expected)
    }

    func testConfigYAML() {
        let yaml = """
        # go2rtc for the nursery
        api:
          listen: ":1984"
        streams:
          kitchen:
            - rtsp://a:b@192.168.0.50:554/live
          nursery:
            # the camera itself
            - rtsp://u%40x:p%3Ass@192.168.0.197:554/stream1
            - "ffmpeg:nursery#audio=opus"
          nursery_sd:
            - rtsp://u%40x:p%3Ass@192.168.0.197:554/stream2 # the sub stream
        webrtc:
          candidates:
            - 192.168.0.136:8555
        """
        let r = ServerMigration.parse(configYAML: yaml, main: "nursery", small: "nursery_sd")
        XCTAssertEqual(r, expected)
    }

    func testNoRTSPProducer() {
        let json = #"{"nursery":{"producers":[{"url":"ffmpeg:device?video=0"}]},"nursery_sd":{"producers":[{"url":"ffmpeg:nursery#video=h264"}]}}"#
        XCTAssertNil(ServerMigration.parse(streamsJSON: Data(json.utf8), main: "nursery", small: "nursery_sd"))
    }

    func testHikvision() {
        let json = #"""
        {"nursery":{"producers":[{"url":"rtsp://admin:secret@192.168.1.64:554/Streaming/Channels/101"}]},
         "nursery_sd":{"producers":[{"url":"rtsp://admin:secret@192.168.1.64:554/Streaming/Channels/102"}]}}
        """#
        let r = ServerMigration.parse(streamsJSON: Data(json.utf8), main: "nursery", small: "nursery_sd")
        XCTAssertEqual(r?.brand, .hikvision)
        XCTAssertEqual(r?.host, "192.168.1.64")
        XCTAssertEqual(r?.mainPath, "Streaming/Channels/101")
        XCTAssertEqual(r?.smallPath, "Streaming/Channels/102")
        XCTAssertEqual(r?.user, "admin")
    }
}
