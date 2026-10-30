#!/usr/bin/env bash
# 순수 로직 점검 (권한·화면 불필요). 고양이 저장소(pet/)가 있으면 지형 계산도 같이 본다.
set -euo pipefail
cd "$(dirname "$0")/.."
./setup-pet.sh
S=Sources/ActLog
PET=()
[[ -f $S/Pet/PetTerrain.swift ]] && PET=($S/Pet/PetTerrain.swift $S/Pet/PetMarks.swift -D HAS_PET)
mkdir -p .build
swiftc -O -o .build/logic-test $S/Context.swift $S/Store.swift $S/AX.swift $S/TextCapture.swift $S/AIResponseCapture.swift $S/QuotaRules.swift $S/ResourceRules.swift $S/CleanupRules.swift $S/ShortcutRules.swift "${PET[@]}" Tests/logic/main.swift -lsqlite3
.build/logic-test
