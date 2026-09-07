#!/bin/zsh
# 按模板在当前目录新建文件
# $1 = 目标目录；ANYWHERE_VARIANT = 模板文件名；ANYWHERE_TEMPLATES = 模板目录
set -e
template="$ANYWHERE_TEMPLATES/$ANYWHERE_VARIANT"
name="${ANYWHERE_VARIANT%.*}"
ext="${ANYWHERE_VARIANT##*.}"
[[ "$name" == "$ANYWHERE_VARIANT" ]] && ext=""
dest="$1/$ANYWHERE_VARIANT"
n=2
while [[ -e "$dest" ]]; do
  if [[ -n "$ext" ]]; then dest="$1/$name $n.$ext"; else dest="$1/$name $n"; fi
  n=$((n+1))
done
cp "$template" "$dest"
open -R "$dest"
echo "${dest##*/}"
