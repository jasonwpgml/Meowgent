#!/usr/bin/env bash
# Sources/ActLog/Pet 링크를 만든다: 비공개 고양이 저장소(../pet, 서브모듈)가 있으면 그쪽,
# 없으면 PetStub(빈 껍데기 — 고양이 없이 수집기만). build.sh·release.sh·Tests/run_logic.sh 가 먼저 부른다.
set -euo pipefail
cd "$(dirname "$0")"
LINK=Sources/ActLog/Pet
if [[ -f ../pet/Sources/PetController.swift ]]; then
  TARGET=../../../pet/Sources; WHAT="비공개 고양이 (pet/)"
else
  TARGET=../../PetStub/Sources; WHAT="빈 껍데기 (PetStub) — 고양이 없이 수집기만. 고양이 저장소가 있으면: git submodule update --init"
fi
if [[ -e $LINK && ! -L $LINK ]]; then
  echo "$LINK 가 링크가 아니라 실제 폴더다. 옮기거나 지운 뒤 다시 실행" >&2; exit 1
fi
if [[ ! -L $LINK || $(readlink "$LINK") != "$TARGET" ]]; then
  ln -sfn "$TARGET" "$LINK"
  echo "Pet → $WHAT"
fi
