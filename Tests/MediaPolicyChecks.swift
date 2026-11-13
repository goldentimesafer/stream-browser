import Foundation

@main
struct MediaPolicyChecks {
    static func main() throws {
        let root = URL(string: "https://video.example.org/stream/index.m3u8")!
        let hosts: Set<String> = ["video.example.org", "cdn.example.org"]
        precondition(MediaPolicy.publicURL(root, hosts: hosts))
        precondition(!MediaPolicy.publicURL(URL(string: "https://video.example.org/a?token=secret")!, hosts: hosts))
        precondition(!MediaPolicy.publicURL(URL(string: "https://u@video.example.org/a")!, hosts: hosts))
        precondition(!MediaPolicy.publicURL(URL(string: "https://video.example.org:444/a")!, hosts: hosts))
        precondition(MediaPolicy.publicHost("192.168.0.1") == nil)
        precondition(MediaPolicy.displayName("../a\\b\u{202E}") == "..ab")
        precondition(MediaPolicy.hasMovieHeader(Data([0, 0, 0, 20, 102, 116, 121, 112, 105, 115, 111, 109])))
        precondition(!MediaPolicy.hasMovieHeader(Data("<html>Denied</html>".utf8)))

        let master = try HLSManifest("""
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="Main, English",URI="https://cdn.example.org/audio.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=800000,AUDIO="a"
            video.m3u8
            """, base: root, hosts: hosts)
        precondition(master.playlists.map(\.absoluteString) == ["https://cdn.example.org/audio.m3u8", "https://video.example.org/stream/video.m3u8"])
        let vod = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXTINF:6,\npart.m4s\n#EXT-X-ENDLIST"
        let valid = try HLSManifest(vod, base: root, hosts: hosts)
        precondition(valid.playlists.isEmpty)
        for invalid in [
            vod.replacingOccurrences(of: "#EXT-X-ENDLIST", with: ""),
            vod.replacingOccurrences(of: "#EXTINF:6,", with: "#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n#EXTINF:6,"),
            vod.replacingOccurrences(of: "part.m4s", with: "http://video.example.org/part.m4s"),
            vod.replacingOccurrences(of: "part.m4s", with: "https://other.example.org/part.m4s"),
            vod.replacingOccurrences(of: "part.m4s", with: "part.m4s?signature=abc"),
            vod.replacingOccurrences(of: "init.mp4", with: "//other.example.org/init.mp4"),
            vod.replacingOccurrences(of: "#EXTINF:6,", with: "#EXT-X-CONTENT-STEERING:SERVER-URI=\"elsewhere\"\n#EXTINF:6,")
        ] {
            precondition((try? HLSManifest(invalid, base: root, hosts: hosts)) == nil)
        }
        print("Media policy checks passed")
    }
}
