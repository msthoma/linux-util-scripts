#!/bin/bash
for file in *.mp3; do
    filename="${file%.*}"
    ffmpeg -i "$file" -c:a libopus -b:a 32k "${filename}.opus" &
done
wait

