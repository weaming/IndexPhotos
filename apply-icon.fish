#!/usr/bin/env fish

set PROJECT_ROOT (dirname (status --current-filename))
cd "$PROJECT_ROOT"; or exit 1

set SOURCE_SVG IndexPhotos/Resources/index-photos-logo.svg
set ASSETS_DIR IndexPhotos/Assets.xcassets/AppIcon.appiconset
set TEMP_ROOT tmp
set ICON_OUTPUT "$TEMP_ROOT/IndexPhotos.icns"

if not test -f "$SOURCE_SVG"
    echo "错误：找不到文件 $SOURCE_SVG"
    exit 1
end

if not type -q sips
    echo "错误：找不到 sips"
    exit 1
end

if not type -q iconutil
    echo "错误：找不到 iconutil"
    exit 1
end

mkdir -p "$TEMP_ROOT" "$ASSETS_DIR"
set WORK_DIR (mktemp -d "$TEMP_ROOT/index-photos-icon.XXXXXX")
or begin
    echo "错误：无法创建临时图标目录"
    exit 1
end
set ICONSET_DIR "$WORK_DIR/IndexPhotos.iconset"
mkdir -p "$ICONSET_DIR"

function cleanup --on-event fish_exit
    if test -d "$WORK_DIR"
        rm -r -- "$WORK_DIR"
    end
end

echo "🎨 生成 IndexPhotos 图标..."
echo "📁 源文件: $SOURCE_SVG"

set SOURCE_IMAGE "$WORK_DIR/source-1024.png"
sips -s format png -Z 1024 "$SOURCE_SVG" --out "$SOURCE_IMAGE" >/dev/null
or begin
    echo "错误：无法将 SVG 转换为 1024px PNG"
    exit 1
end

function render_icon
    set size $argv[1]
    set filename $argv[2]
    sips -z "$size" "$size" "$SOURCE_IMAGE" --out "$ICONSET_DIR/$filename" >/dev/null
    or begin
        echo "错误：无法生成 $filename"
        exit 1
    end
end

render_icon 16 icon_16x16.png
render_icon 32 icon_16x16@2x.png
render_icon 32 icon_32x32.png
render_icon 64 icon_32x32@2x.png
render_icon 128 icon_128x128.png
render_icon 256 icon_128x128@2x.png
render_icon 256 icon_256x256.png
render_icon 512 icon_256x256@2x.png
render_icon 512 icon_512x512.png
render_icon 1024 icon_512x512@2x.png

cp "$ICONSET_DIR"/icon_*.png "$ASSETS_DIR"/
or begin
    echo "错误：无法复制图标资源"
    exit 1
end

iconutil -c icns "$ICONSET_DIR" -o "$ICON_OUTPUT"
or begin
    echo "错误：无法生成 $ICON_OUTPUT"
    exit 1
end

echo "✅ AppIcon 资源已更新"
echo "💾 ICNS 已生成: $ICON_OUTPUT"
