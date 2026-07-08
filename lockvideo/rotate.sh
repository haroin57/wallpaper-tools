#!/bin/bash
# 解除トリガー専用: 双子スロット交互切替(killallなし)。
# WallpaperCreationRequestに毎回差分を作り、公式のinvalidate()+新規init()経路を誘導する。
export PATH="/opt/homebrew/bin:$HOME/bin:/usr/bin:/bin"
/usr/bin/python3 "$(cd "$(dirname "$0")" && pwd)/apply.py" --rotate >> /tmp/lockvideo.log 2>&1
