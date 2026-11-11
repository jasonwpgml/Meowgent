#!/usr/bin/env python3
"""끝남 알림 홀드아웃 실험 결과 (읽기만 한다).

에이전트 "답 끝남" 알림의 절반을 일부러 안 보여 주고(withheld) 나머지는 보여 줬다(shown).
둘 다 같은 행동 창(10분)으로 '그 앱으로 감(acted)'을 쟀으니, 두 비율의 차이가 이 알림이 행동을 바꾼 정도다.

결정 기준 (2026-11-10 Fable 검토안):
  2분 안에 돌아간 비율 차이가 10%p 이하 → 끝남 말풍선은 끄고 메뉴 요약만
  20%p 이상 → 유지, 다른 종류로 홀드아웃을 넓힌다
  그 사이 → '다른 앱에 오래 있었을 때만'처럼 조건을 좁혀 다시

쓰는 법: python3 brain/holdout_report.py [reactions.jsonl 경로]
"""
import json
import math
import os
import sys

DEFAULT = os.path.expanduser("~/Library/Application Support/ActLog/reactions.jsonl")


def load(path):
    with open(path, encoding="utf-8") as f:
        for line in f:
            try:
                yield json.loads(line)
            except ValueError:
                continue


def arms(rows):
    """id 별로 묶어 끝남 알림만: {"shown": [acted 까지 초 또는 None, ...], "withheld": [...]}"""
    first, acted = {}, {}
    for o in rows:
        i, ev = o.get("id"), o.get("ev")
        if ev in ("shown", "withheld") and o.get("src") == "agent" and o.get("tag") == "done":
            first.setdefault(i, ev)
        elif ev == "acted" and i not in acted:
            acted[i] = o.get("after")
    out = {"shown": [], "withheld": []}
    for i, ev in first.items():
        out[ev].append(acted.get(i))
    return out


def wilson(k, n, z=1.96):
    if n == 0:
        return (0.0, 0.0)
    p = k / n
    d = 1 + z * z / n
    c = p + z * z / (2 * n)
    r = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))
    return ((c - r) / d, (c + r) / d)


def rate(xs, within):
    k = sum(1 for a in xs if a is not None and a <= within)
    return k, len(xs)


def verdict(diff_pp):
    if diff_pp <= 10:
        return "차이가 작다 → 끝남 말풍선은 끄고 메뉴 요약만 남길 쪽"
    if diff_pp >= 20:
        return "차이가 크다 → 끝남 말풍선 유지, 다른 종류로 홀드아웃 넓히기"
    return "애매하다 → 조건을 좁혀(다른 앱에 오래 있었을 때만 등) 다시 재기"


def report(rows):
    a = arms(rows)
    lines = [f"끝남 알림: 보여 줌 {len(a['shown'])}건 · 안 보여 줌 {len(a['withheld'])}건"]
    if min(len(a["shown"]), len(a["withheld"])) < 20:
        lines.append("아직 적다 (양쪽 20건 넘어야 볼 만하다, 2주면 100건 안팎)")
    diff2 = None
    for within, name in ((120, "2분"), (600, "10분")):
        ks, ns = rate(a["shown"], within)
        kw, nw = rate(a["withheld"], within)
        if ns == 0 or nw == 0:
            continue
        ps, pw = ks / ns, kw / nw
        ls, hs = wilson(ks, ns)
        lw, hw = wilson(kw, nw)
        d = (ps - pw) * 100
        if within == 120:
            diff2 = d
        lines.append(f"{name} 안에 그 앱으로 감: 보여 줌 {ps:.0%} ({ls:.0%}~{hs:.0%}) · 안 보여 줌 {pw:.0%} ({lw:.0%}~{hw:.0%}) · 차이 {d:+.0f}%p")
    if diff2 is not None:
        lines.append("판단: " + verdict(diff2))
    return "\n".join(lines)


if __name__ == "__main__":
    print(report(load(sys.argv[1] if len(sys.argv) > 1 else DEFAULT)))
