import CatVodSource
@testable import CatVodUI
import Testing

/// 「这一部片子该显示哪张图」：优先级、代理改写、去重、空集（M11）。
struct TMDBPosterSetTests {
    private func metadata(poster: String, backdrop: String) -> TMDBMetadata {
        TMDBMetadata(
            id: 1,
            kind: .tv,
            title: "仙逆",
            overview: "",
            posterPath: poster,
            backdropPath: backdrop
        )
    }

    @Test("图集优先，且地址统一过图片代理（不在别处再拼一次）")
    func backdropsWinAndAreRewritten() {
        let set = TMDBPosterSet(
            metadata: metadata(poster: "/p.jpg", backdrop: "/b.jpg"),
            backdrops: ["/x1.jpg", "/x2.jpg"],
            config: TMDBConfig(imageProxy: "https://img.example/"),
            mode: .rotate
        )
        #expect(set.urls.count == 3) // 两张图集 + 主背景
        #expect(set.urls[0] == "https://img.example/https://image.tmdb.org/t/p/original/x1.jpg")
        #expect(set.image(step: 1) == set.urls[1])
    }

    @Test("图集为空时退回主背景，再退回海报 —— 总有图能显示")
    func fallsBackToPoster() {
        let backdropOnly = TMDBPosterSet(
            metadata: metadata(poster: "/p.jpg", backdrop: "/b.jpg"),
            backdrops: [],
            config: TMDBConfig(),
            mode: .fixed
        )
        #expect(backdropOnly.urls == ["https://image.tmdb.org/t/p/original/b.jpg"])

        let posterOnly = TMDBPosterSet(
            metadata: metadata(poster: "/p.jpg", backdrop: ""),
            backdrops: [],
            config: TMDBConfig(),
            mode: .fixed
        )
        #expect(posterOnly.urls == ["https://image.tmdb.org/t/p/original/p.jpg"])
    }

    @Test("同一个路径出现两次只留一张")
    func dedupes() {
        let set = TMDBPosterSet(
            metadata: metadata(poster: "", backdrop: "/b.jpg"),
            backdrops: ["/b.jpg", "/b.jpg"],
            config: TMDBConfig(),
            mode: .fixed
        )
        #expect(set.urls == ["https://image.tmdb.org/t/p/original/b.jpg"])
    }

    @Test("一张图都没有：isEmpty 为真，取图给 nil（界面显示占位）")
    func emptyGivesNil() {
        for mode in PosterMode.allCases {
            let set = TMDBPosterSet(
                metadata: metadata(poster: "", backdrop: ""),
                backdrops: [],
                config: TMDBConfig(),
                mode: mode
            )
            #expect(set.isEmpty)
            #expect(set.image(step: 3, seed: 7) == nil)
        }
    }
}
