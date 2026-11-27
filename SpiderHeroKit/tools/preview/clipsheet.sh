#!/bin/bash
# Usage: tools/preview/clipsheet.sh <Clip> <frames comma list> <cols> [view] [w] [h] [extra shoot args...]
set -e
CLIP=$1; FRAMES=$2; COLS=$3
VIEW=${4:-"side:8.5,3.0,0:0,2.6,0:34"}
W=${5:-360}; H=${6:-420}
shift 6 2>/dev/null || true
OUT=tools/preview/out/sheets/$CLIP
rm -rf $OUT; mkdir -p $OUT
node tools/preview/shoot.mjs --out $OUT --prefix f --w $W --h $H --views "$VIEW" --poses out/clip_$CLIP.json --frames $FRAMES --follow 1 --grid 1 "$@" > $OUT/list.txt
python3 tools/preview/sheet.py tools/preview/out/sheets/${CLIP}_sheet.png $COLS $(cat $OUT/list.txt)
echo tools/preview/out/sheets/${CLIP}_sheet.png
