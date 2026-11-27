import Foundation
import Testing
@testable import KumoneCore

@Suite("pyncmd data proxy routing")
struct PyncmdProxyTests {
    @Test func authenticationAndPlaylistReadsKeepTheAppSession() {
        let paths = [
            "/login/qrcode/unikey",
            "/login/qrcode/client/login",
            "/login/token/refresh",
            "/logout",
            "/w/login/cellphone",
            "/sms/captcha/sent",
            "/nuser/account/get",
            "/user/playlist",
            "/v6/playlist/detail",
            "/song/like/get",
        ]
        for path in paths {
            #expect(PyncmdProxy.keepsDirectSession(path: path), "\(path) should stay direct")
        }
    }

    @Test func catalogPlaybackAndWritesUsePyncmd() {
        let paths = [
            "/song/enhance/player/url/v1",
            "/song/enhance/download/url/v1",
            "/v3/song/detail",
            "/song/lyric/v1",
            "/cloudsearch/pc",
            "/v1/resource/comments/R_SO_4_1",
            "/playlist/create",
            "/playlist/manipulate/tracks",
            "/radio/like",
            "/feedback/weblog",
            "/album/sub",
            "/artist/sub",
            "/v1/cloud/get",
        ]
        for path in paths {
            #expect(!PyncmdProxy.keepsDirectSession(path: path), "\(path) should use pyncmd")
        }
    }

    @Test func sessionPayloadCarriesLoginAndCookies() throws {
        let json = #"{"code":200,"logged_in":true,"nickname":"Demo","uid":7,"cookies":{"MUSIC_U":"u","__csrf":"c"}}"#
        let session = try JSONDecoder().decode(PyncmdProxy.Session.self, from: Data(json.utf8))
        #expect(session.loggedIn)
        #expect(session.uid == 7)
        #expect(session.nickname == "Demo")
        #expect(session.cookies?["MUSIC_U"] == "u")
        #expect(session.cookies?["__csrf"] == "c")
    }

    @Test func signedOutSessionPayloadDecodesWithoutCookies() throws {
        let json = #"{"code":200,"logged_in":false,"status":{"logged_in":false}}"#
        let session = try JSONDecoder().decode(PyncmdProxy.Session.self, from: Data(json.utf8))
        #expect(!session.loggedIn)
        #expect(session.uid == nil)
        #expect(session.cookies == nil)
    }
}
