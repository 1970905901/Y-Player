#!/usr/bin/env python3
"""从一张主图生成 iOS / macOS 的 AppIcon（Xcode 14+ 的「单尺寸 1024」形态）。

两个 target 的 `AppIcon.appiconset` 都只放**一张** 1024×1024：`Contents.json` 里是一条
`universal` + `platform: ios|macos` 记录，actool 会自行降采样（iPhone/iPad 全尺寸、
macOS 16pt–512pt@2x），因此不需要手工切二十来张图。

iOS 那张必须**没有 alpha 通道**：App Store 的 1024 营销图不接受透明，actool 也会警告。
所以统一压平到白底（本图标本身是白底插画，压平后视觉无差），macOS 用同一份产物，
两端图标保持一致。

用法：
    python Scripts/make_app_icons.py                      # 用入库主图生成两张图标（默认裁白边+居中）
    python Scripts/make_app_icons.py --no-trim             # 保留主图原始留白（不裁白边、不居中）
    python Scripts/make_app_icons.py --source 新图.png      # 换主图（同时覆盖入库主图）
    python Scripts/check_app_icons.py                      # 生成后校验（CI 跑的就是它，纯标准库）

依赖 Pillow（`pip install pillow`）：只在**改图**时需要；CI 跑的是纯标准库的
`Scripts/check_app_icons.py`，所以 CI 不依赖 Pillow。
"""

from __future__ import annotations

import os
import shutil
import sys

from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# 入库主图：设计稿原件（2048×2048 白底插画），产物由它派生，便于日后换图标时复现。
MASTER = os.path.join(ROOT, "docs", "images", "app-icon-master.png")
ICON_SIZE = 1024
TARGETS = (
    os.path.join(ROOT, "Apps", "YPlayer-iOS", "Assets.xcassets", "AppIcon.appiconset"),
    os.path.join(ROOT, "Apps", "YPlayer-macOS", "Assets.xcassets", "AppIcon.appiconset"),
)
ICON_NAME = "AppIcon-%d.png" % ICON_SIZE
# 裁白边时认为「背景」的亮度阈值：主图是白底插画，四周还有一层极淡的渐变/暗角，
# 取 248 能连柔影一起保留、把暗角排除在外。
TRIM_THRESHOLD = 248
# 裁完补回的内边距比例（每侧）：0.06 → 主体约占画布 88%，留出 iOS 圆角遮罩切割的余量。
TRIM_PADDING = 0.06


def flatten(image: Image.Image) -> Image.Image:
    """压平到白底、丢掉 alpha 通道（iOS 的 1024 图标不允许透明）。"""
    rgba = image.convert("RGBA")
    flattened = Image.new("RGB", rgba.size, (255, 255, 255))
    flattened.paste(rgba, mask=rgba.split()[3])
    return flattened


def trim_background(image: Image.Image) -> Image.Image:
    """裁掉四周留白再居中（顺带修正主图的偏心），让主体在图标里更饱满。"""
    mask = image.convert("L").point(lambda value: 255 if value < TRIM_THRESHOLD else 0)
    box = mask.getbbox()
    if box is None:
        print("trim: 找不到内容，跳过（整张图都是白底？）")
        return image
    cropped = image.crop(box)
    width, height = cropped.size
    side = max(width, height)
    padded = int(round(side * (1 + TRIM_PADDING * 2)))
    canvas = Image.new("RGB", (padded, padded), (255, 255, 255))
    canvas.paste(cropped, ((padded - width) // 2, (padded - height) // 2))
    print("trim: %dx%d -> %dx%d（每侧 %.0f%% 内边距、居中）" % (
        width,
        height,
        padded,
        padded,
        TRIM_PADDING * 100,
    ))
    return canvas


def fit_square(image: Image.Image) -> Image.Image:
    """居中裁成正方形（主图不是 1:1 时也能用），再缩到 1024×1024。"""
    width, height = image.size
    if width != height:
        side = min(width, height)
        left = (width - side) // 2
        top = (height - side) // 2
        image = image.crop((left, top, left + side, top + side))
        print("crop: %dx%d -> %dx%d（居中）" % (width, height, side, side))
    resampling = getattr(Image, "Resampling", Image).LANCZOS
    return image.resize((ICON_SIZE, ICON_SIZE), resampling)


def main() -> int:
    source = MASTER
    if "--source" in sys.argv:
        index = sys.argv.index("--source")
        if index + 1 >= len(sys.argv):
            print("用法：python Scripts/make_app_icons.py [--source <主图路径>] [--trim]")
            return 2
        source = os.path.abspath(sys.argv[index + 1])
    if not os.path.exists(source):
        print("MISSING: %s" % source)
        return 1

    if os.path.abspath(source) != MASTER:
        os.makedirs(os.path.dirname(MASTER), exist_ok=True)
        shutil.copyfile(source, MASTER)
        print("master: %s（已更新入库主图）" % os.path.relpath(MASTER, ROOT))

    with Image.open(source) as image:
        print("source: %s %dx%d mode=%s" % (
            os.path.relpath(source, ROOT),
            image.size[0],
            image.size[1],
            image.mode,
        ))
        icon = flatten(image)

    if "--no-trim" not in sys.argv:
        icon = trim_background(icon)
    icon = fit_square(icon)

    for directory in TARGETS:
        target = os.path.join(directory, ICON_NAME)
        icon.save(target, format="PNG", optimize=True)
        print("wrote: %s（%d×%d、%s、%d bytes）" % (
            os.path.relpath(target, ROOT),
            icon.size[0],
            icon.size[1],
            icon.mode,
            os.path.getsize(target),
        ))

    print("下一步：python Scripts/check_app_icons.py，然后提交主图 + 两张图标")
    return 0


if __name__ == "__main__":
    sys.exit(main())
