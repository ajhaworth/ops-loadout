#!/bin/bash
cd "$1" 2>/dev/null || exit
git diff --numstat 2>/dev/null | awk '{a+=$1; b+=$2} END {if(a>0||b>0) printf "#[fg=#4EC994]+%d #[fg=#FF6B6B]-%d", a, b}'
