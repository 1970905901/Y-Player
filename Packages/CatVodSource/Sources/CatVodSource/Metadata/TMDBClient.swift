import CatVodNet
import Foundation

/// TMDB 客户端（M11）：**搜索 / 详情 / 图集**三件事。
///
/// 出来的都是收好的模型，调用方（详情页形态）不需要知道 TMDB 的字段名，也不需要知道
/// 「电视剧叫 `name`、电影叫 `title`」这种差异 —— 那是这里的事。
public struct TMDBClient: Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case movie
        case tv

        /// 详情页角标用：动画在 TMDB 里是 **genre 16**，参考视频里那个「动漫」标就是它。
        public static let animationGenreID = 16
    }

    public let config: TMDBConfig
    public let transport: HTTPTransport
    /// TMDB 的 `language` 参数：中文界面就要中文简介。
    public let language: String

    public init(config: TMDBConfig, transport: HTTPTransport, language: String = "zh-CN") {
        self.config = config
        self.transport = transport
        self.language = language
    }

    /// 搜索（多类型）：`/search/multi`。查不到就给空数组，不抛。
    public func search(_ query: String) async throws -> [TMDBMetadata] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return []
        }
        let body = try await get(path: "search/multi", query: [
            URLQueryItem(name: "query", value: trimmed),
            URLQueryItem(name: "include_adult", value: "false"),
        ])
        let response = try decode(SearchResponse.self, from: body)
        return response.results.compactMap(\.metadata)
    }

    /// 详情：`/movie/{id}` 或 `/tv/{id}` —— 背景图、简介、海报、类型都从这儿来。
    public func details(kind: Kind, id: Int) async throws -> TMDBMetadata {
        let body = try await get(path: "\(kind.rawValue)/\(id)", query: [])
        let item = try decode(DetailDTO.self, from: body)
        guard let metadata = item.metadata(fallbackKind: kind) else {
            throw TMDBError.unusableResult
        }
        return metadata
    }

    /// 图集：`/{kind}/{id}/images` 的**背景图**路径。
    ///
    /// 顶部「随机 / 轮播」的多张图就是它 —— 只有一张时三种取图模式等价
    /// （``PosterPicker`` 那边不用特判）。
    public func backdrops(kind: Kind, id: Int) async throws -> [String] {
        let body = try await get(path: "\(kind.rawValue)/\(id)/images", query: [])
        return try decode(ImagesResponse.self, from: body).usableBackdrops
    }

    // MARK: - 传输与解码

    private func get(path: String, query: [URLQueryItem]) async throws -> Data {
        guard config.isConfigured else {
            // 没配 key 就不发请求 —— 「切到 Emby 才要求填」，别在后台打无效请求。
            throw TMDBError.notConfigured
        }
        let full = [URLQueryItem(name: "language", value: language)] + query
        guard let url = config.apiURL(path: path, query: full) else {
            throw TMDBError.badURL
        }
        let request = HTTPRequest(url: url, method: .get, headers: [:], body: nil, timeout: nil)
        let response = try await transport.send(request)
        guard response.isSuccess else {
            throw TMDBError.badStatus(response.status)
        }
        return response.body
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw TMDBError.undecodable(String(describing: error))
        }
    }
}

// MARK: - 收原始 JSON 的那层（只在这儿出现 TMDB 的字段名）

private struct SearchResponse: Decodable {
    var results: [ResultDTO] = []
}

private struct ImagesResponse: Decodable {
    var backdrops: [ImageDTO] = []

    /// 只留真有路径的（TMDB 会给空串项）。
    var usableBackdrops: [String] {
        backdrops.compactMap { item in
            guard let path = item.filePath, !path.isEmpty else {
                return nil
            }
            return path
        }
    }
}

private struct ImageDTO: Decodable {
    var filePath: String?

    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
    }
}

private struct ResultDTO: Decodable {
    var id: Int?
    var mediaType: String?
    var title: String?
    var name: String?
    var overview: String?
    var posterPath: String?
    var backdropPath: String?
    var genreIDs: [Int]?

    enum CodingKeys: String, CodingKey {
        case id
        case mediaType = "media_type"
        case title
        case name
        case overview
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case genreIDs = "genre_ids"
    }

    /// `media_type` 只认 movie / tv（`person` 之类直接丢掉，别塞进结果里）。
    var metadata: TMDBMetadata? {
        guard let id, let kind = mediaType.flatMap(TMDBClient.Kind.init(rawValue:)) else {
            return nil
        }
        return TMDBMetadata(
            id: id,
            kind: kind,
            title: title ?? name ?? "",
            overview: overview ?? "",
            posterPath: posterPath ?? "",
            backdropPath: backdropPath ?? "",
            genreIDs: genreIDs ?? []
        )
    }
}

private struct DetailDTO: Decodable {
    var id: Int?
    var title: String?
    var name: String?
    var overview: String?
    var posterPath: String?
    var backdropPath: String?
    var genres: [GenreDTO]?

    struct GenreDTO: Decodable {
        var id: Int?
    }

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case name
        case overview
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case genres
    }

    func metadata(fallbackKind: Kind) -> TMDBMetadata? {
        guard let id else {
            return nil
        }
        return TMDBMetadata(
            id: id,
            kind: title == nil ? fallbackKind : .movie,
            title: title ?? name ?? "",
            overview: overview ?? "",
            posterPath: posterPath ?? "",
            backdropPath: backdropPath ?? "",
            genreIDs: genres?.compactMap(\.id) ?? []
        )
    }

    typealias Kind = TMDBClient.Kind
}

/// TMDB 那一层会出的错（与站点错误分开，界面能分开说）。
public enum TMDBError: Error, Equatable {
    /// 没填 api key —— 「切到 Emby 才要求填」，这时整层不工作。
    case notConfigured
    case badURL
    case badStatus(Int)
    /// 结果里没有 id（TMDB 偶尔给这种残缺项）：按不可用处理，不硬塞。
    case unusableResult
    case undecodable(String)

    public static func == (lhs: TMDBError, rhs: TMDBError) -> Bool {
        switch (lhs, rhs) {
        case (.notConfigured, .notConfigured), (.badURL, .badURL), (.unusableResult, .unusableResult):
            true
        case let (.badStatus(a), .badStatus(b)):
            a == b
        case let (.undecodable(a), .undecodable(b)):
            a == b
        default:
            false
        }
    }
}

/// 收好的 TMDB 元信息 —— Emby 视图详情页要的就是这几样（标题 / 简介 / 海报 / 背景 / 类型）。
public struct TMDBMetadata: Sendable, Hashable {
    public var id: Int
    public var kind: TMDBClient.Kind
    /// 中文名优先（`language=zh-CN`），没有就原名。
    public var title: String
    /// 简介：TMDB overview，**可能为空串**（界面按空处理，别显示空行）。
    public var overview: String
    /// `/abc.jpg` 形式的路径：拼地址交给 ``TMDBConfig/imageURL(_:)``（要过图片代理）。
    public var posterPath: String
    public var backdropPath: String
    public var genreIDs: [Int]

    public init(
        id: Int,
        kind: TMDBClient.Kind,
        title: String,
        overview: String,
        posterPath: String,
        backdropPath: String,
        genreIDs: [Int] = []
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.overview = overview
        self.posterPath = posterPath
        self.backdropPath = backdropPath
        self.genreIDs = genreIDs
    }

    /// 参考视频里那个「动漫」角标（TMDB 的动画类型）。
    public var isAnimation: Bool {
        genreIDs.contains(TMDBClient.Kind.animationGenreID)
    }
}
