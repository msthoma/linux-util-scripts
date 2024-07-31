#!/bin/bash

# copied from https://news.ycombinator.com/item?id=40658453

screenshot=$(mktemp)
decoded_data=$(mktemp)
processed_data=$(mktemp)

cleanup() {
    rm "$screenshot" "$decoded_data" "$processed_data"
}

trap cleanup EXIT

flameshot gui -s -r > "$screenshot"

convert "$screenshot" \
    -colorspace Gray \
    -scale 1191x2000 \
    -unsharp 6.8x2.69+0 \
        -resize 500% \
    "$screenshot"

tesseract \
    --dpi 300 \
    --oem 1 "$screenshot" - > "$decoded_data"

grep -v '^\s*$' "$decoded_data" > "$processed_data"

cat "$processed_data" | \
    xclip -selection clipboard

yad --text-info --title="Decoded Data" \
    --width=940 \
    --height=580 \
    --wrap \
    --fontname="Iosevka 14" \
    --editable \
    --filename="$processed_data"

# or from cli bash -c 'flameshot gui -s -r | tesseract - - | gxmessage -title "Decoded Data" -fn "Consolas 12" -wrap -geometry 640x480 -file -'
