@testable import CatVodSource
import Foundation
import Testing

/// TMDB 配置（M11）：接口地址、图片地址、代理的两种写法。
struct TMDBConfigTests {
    @Test("没配 api key 时这一层不算配好（切到 Emby 才要求填）")
    func configuredNeedsAPIKey() {
        #expect(!TMDBConfig().isConfigured)
        #expect(!TMDBConfig(apiProxy: "https://p.example").isConfigured)
        #expect(TMDBConfig(apiKey: "k").isConfigured)
    }

    @Test("接口地址：直连带 api_key，路径拼在 /3/ 下")
    func apiURLDirect() throws {
        let url = try #require(TMDBConfig(apiKey: "abc").apiURL(path: "search/multi", query: [
            URLQueryItem(name: "query", value: "仙逆"),
        ]))
        let text = url.absoluteString
        #expect(text.hasPrefix("https://api.themoviedb.org/3/search/multi?"))
        #expect(text.contains("api_key=abc"))
        #expect(text.contains("query="))
    }

    @Test("接口代理：前缀拼接会自动补斜杠，模板写法会替换 {url}")
    func apiProxyForms() throws {
        let prefixed = try #require(TMDBConfig(apiKey: "k", apiProxy: "https://p.example/tmdb").apiURL(path: "movie/1"))
        #expect(prefixed.absoluteString.hasPrefix("https://p.example/tmdb/https://api.themoviedb.org/3/movie/1"))

        let templated = try #require(TMDBConfig(apiKey: "k", apiProxy: "https://p.example?u={url}").apiURL(path: "movie/1"))
        #expect(templated.absoluteString.hasPrefix("https://p.example?u=https://api.themoviedb.org/3/movie/1"))
    }

    @Test("图片地址：路径拼成 original 尺寸的完整地址，空串给 nil")
    func imageURLBasics() throws {
        let direct = try #require(TMDBConfig().imageURL("/abc.jpg"))
        #expect(direct.absoluteString == "https://image.tmdb.org/t/p/original/abc.jpg")

        // 已经是完整地址就原样（换过源的图不该被再拼一次）
        let full = try #require(TMDBConfig().imageURL("https://cdn.example/x.jpg"))
        #expect(full.absoluteString == "https://cdn.example/x.jpg")

        #expect(TMDBConfig().imageURL("") == nil)
        #expect(TMDBConfig().imageURL("   ") == nil)
    }

    @Test("图片代理：两种写法都认")
    func imageProxyForms() throws {
        let prefixed = try #require(TMDBConfig(imageProxy: "https://img.example/").imageURL("/abc.jpg"))
        #expect(prefixed.absoluteString == "https://img.example/https://image.tmdb.org/t/p/original/abc.jpg")

        let templated = try #require(TMDBConfig(imageProxy: "https://img.example/p?src={url}&w=780").imageURL("/abc.jpg"))
        #expect(templated.absoluteString == "https://img.example/p?src=https://image.tmdb.org/t/p/original/abc.jpg&w=780")
    }
}
