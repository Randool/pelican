#!/bin/bash
# No test framework here, so the checks are the few that can actually fail:
#   1. the page's JS parses
#   2. the copy bundled into the app matches the source byte for byte
#   3. a headless run proves JS really changed the DOM
#   4. drivetrain: one crank turn, two wheel turns, chain by sprocket radius
#   5. coasting: feet stop, wheels keep rolling
#   6. time of day: day and night really swap the light
#   7. each scrolling strip is one build plus an exact copy, so the seam is even
#   8. parked: the near foot props on the sand, riding: both feet on the pedals
#   9. a burst climbs straight to the moto, no e-bike frame on the way up
#  10. the headlamp beam lands on the sand ahead, and only at night
# Any of these failing means an edit broke something. Usage: ./check.sh
set -euo pipefail
cd "$(dirname "$0")"

CH="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "· JS 语法"
python3 - "$TMP/app.js" <<'PY'
import re, sys
html = open('app/pelican.html', encoding='utf-8').read()
blocks = re.findall(r'<script>(.*?)</script>', html, re.S)
assert blocks, '页面里没找到 <script> 块'
open(sys.argv[1], 'w', encoding='utf-8').write('\n;\n'.join(blocks))
PY
node --check "$TMP/app.js"

echo "· 打包副本与源文件一致"
./app/build.sh > /dev/null
cmp app/pelican.html app/PelicanFloat.app/Contents/Resources/pelican.html

echo "· 无头跑一帧，检查 JS 真的改到了 DOM"
"$CH" --headless=new --disable-gpu --hide-scrollbars --window-size=1200,700 \
  --user-data-dir="$TMP/cp" --virtual-time-budget=2000 --dump-dom \
  "file://$PWD/app/pelican.html#rate=1500&t=3" > "$TMP/dom.html" 2>/dev/null

fail() { echo "  ✗ $1"; exit 1; }
# fast should be the moto: bike hidden, moto shown
grep -q 'id="bike" style="display: none' "$TMP/dom.html" || fail '高速下自行车没藏起来'
grep -q 'id="moto" style=""' "$TMP/dom.html" || fail '高速下摩托车没显示'
# crank and pedals are written every frame
grep -q 'id="crankG" transform="rotate(' "$TMP/dom.html" || fail '曲柄没被转动'
# pedals orbit the crank end (r=40) but the plate never flips: foot stays flat
python3 - "$TMP/dom.html" <<'PY'
import math, re, sys
dom = open(sys.argv[1], encoding='utf-8').read()
for pid in ('pedalA', 'pedalB'):
    m = re.search(rf'id="{pid}" transform="([^"]*)"', dom)
    assert m, f'{pid} 没有 transform'
    t = m.group(1)
    assert 'rotate' not in t, f'{pid} 板面被翻转了：{t}'
    x, y = map(float, re.search(r'translate\(([\d.]+) ([\d.]+)\)', t).groups())
    assert abs(math.hypot(x - 405, y - 416) - 40) < 2, f'{pid} 不在曲柄臂末端：({x:.1f}, {y:.1f})'
PY

echo "· 传动：齿比和链条对得上"
pedal() {
  "$CH" --headless=new --disable-gpu --hide-scrollbars --window-size=1200,700 \
    --user-data-dir="$TMP/cp$1" --virtual-time-budget=2500 --dump-dom \
    "file://$PWD/app/pelican.html#rate=150&t=$1" > "$TMP/pedal$1.html" 2>/dev/null
}
pedal 2
pedal 2.8
python3 - "$TMP/pedal2.html" "$TMP/pedal2.8.html" <<'PY'
import math, re, sys
def grab(path):
    dom = open(path, encoding='utf-8').read()
    def num(i, attr):
        return float(re.search(rf'id="{i}"[^>]*{attr}="([-\d.]+)', dom).group(1))
    crank = float(re.search(r'id="crankG" transform="rotate\(([-\d.]+)', dom).group(1))
    wheel = float(re.search(r'id="spinRear" transform="rotate\(([-\d.]+)', dom).group(1))
    chain = num('chainEbike', 'stroke-dashoffset')
    d = re.search(r'id="chainBike"[^>]* d="([^"]+)"', dom).group(1)
    return crank, wheel, chain, d
a, b = grab(sys.argv[1]), grab(sys.argv[2])
dc, dw, dch = b[0] - a[0], b[1] - a[1], b[2] - a[2]
assert dw > 1, f'这段时间轮子没转：Δ{dw:.2f}°'
gear = dc / dw
assert abs(gear - 11 / 22) < 0.01, f'齿比不对：曲柄/后轮 = {gear:.3f}，链轮 22 / 飞轮 11 应该是 0.5'
assert abs(dch - math.radians(dc) * 22) < 0.5, f'链条没跟着曲柄走：链条 Δ{dch:.2f}px，按 R22 应该是 {math.radians(dc) * 22:.2f}px'
d = b[3]
assert d.endswith('Z'), '链条不是闭合回路'
assert 'A 11 11' in d and 'A 22 22' in d, f'链条没绕住两个齿盘：{d}'
PY

echo "· 收工滑行：脚停住、轮子还在转"
coast() {
  "$CH" --headless=new --disable-gpu --hide-scrollbars --window-size=1200,700 \
    --user-data-dir="$TMP/cp$1" --virtual-time-budget=2000 --dump-dom \
    "file://$PWD/app/pelican.html#rate=150&t=3&off=$1" > "$TMP/coast$1.html" 2>/dev/null
}
coast 1.6
coast 2.4
python3 - "$TMP/coast1.6.html" "$TMP/coast2.4.html" <<'PY'
import re, sys
def grab(path):
    dom = open(path, encoding='utf-8').read()
    def deg(i):
        t = re.search(rf'id="{i}" transform="rotate\(([-\d.]+)', dom).group(1)
        return float(t)
    chain = float(re.search(r'id="chainEbike"[^>]*stroke-dashoffset="([-\d.]+)', dom).group(1))
    return deg('crankG'), deg('spinRear'), chain
early, late = grab(sys.argv[1]), grab(sys.argv[2])
assert abs(early[0] - late[0]) < 0.05, f'滑行时曲柄还在动：{early[0]:.1f} -> {late[0]:.1f}（松脚后应该停住）'
assert late[1] - early[1] > 5, f'滑行时轮子没转：{early[1]:.1f} -> {late[1]:.1f}'
assert abs(late[0] % 180) < 0.01 or abs(late[0] % 180 - 180) < 0.01, f'松脚后曲柄没停到水平位：{late[0]:.1f}°'
assert abs(late[2] - early[2]) < 0.1, f'滑行时链条还在走：{early[2]:.1f} -> {late[2]:.1f}（飞轮空转，链条该停）'
PY

echo "· 时段：白天和夜里换的是光"
phase() {
  "$CH" --headless=new --disable-gpu --hide-scrollbars --window-size=1200,700 \
    --user-data-dir="$TMP/ph$1" --virtual-time-budget=1500 --dump-dom \
    "file://$PWD/app/pelican.html#t=1&time=$1" > "$TMP/ph$1.html" 2>/dev/null
}
phase day
phase night
python3 - "$TMP/phday.html" "$TMP/phnight.html" <<'PY'
import re, sys
def grab(path):
    dom = open(path, encoding='utf-8').read()
    sky = re.search(r'id="skyG".*?stop-color="([^"]+)"', dom, re.S).group(1)
    veil = float(re.search(r'id="veil"[^>]*opacity="([\d.]+)"', dom).group(1))
    stars = re.search(r'id="stars"[^>]*style="([^"]*)"', dom)
    sun = re.search(r'id="sunCore"[^>]*fill="([^"]+)"', dom).group(1)
    return sky, veil, stars.group(1) if stars else '', sun
d, n = grab(sys.argv[1]), grab(sys.argv[2])
assert d[0] != n[0], f'白天和夜里天空一个色：{d[0]}'
assert d[1] == 0 and n[1] > .2, f'夜色纱没按阶段开关：day={d[1]} night={n[1]}'
assert 'opacity: 0' in d[2] and 'opacity: 1' in n[2], f'星星只在夜里露出来：day={d[2]!r} night={n[2]!r}'
assert d[3] != n[3], f'太阳和月亮一个色：{d[3]}'
PY

echo "· 沙滩和草地不会在接缝处跳"
python3 - "$TMP/dom.html" <<'PY'
import re, sys
dom = open(sys.argv[1], encoding='utf-8').read()

def kids(ident):
    i = dom.index(f'id="{ident}"')
    seg = dom[dom.index('>', i) + 1:]
    out, depth, start = [], 1, None
    for m in re.finditer(r'<g\b|</g>', seg):
        if m.group(0) == '</g>':
            depth -= 1
            if depth == 1 and start is not None:
                out.append(seg[start:m.start()])
                start = None
            if depth == 0:
                break
        else:
            if depth == 1:
                start = seg.index('>', m.start()) + 1
            depth += 1
    return out

# 每段只画一次，第二份是复制品：两份随机生成会不一样，滚到接头整片换掉就跳一下
for bid in ('clouds', 'waves', 'glitter', 'island', 'foam', 'sandDecor', 'grass'):
    parts = kids(bid)
    assert len(parts) == 2, f'{bid} 应该画两段，实际 {len(parts)} 段'
    assert len(parts[0]) > 100, f'{bid} 抓到的内容是空的，检查本身失效了'
    assert parts[0] == parts[1], f'{bid} 两段内容不一样：滚到接缝会跳一下'
PY

echo "· 停下来撑一脚"
foot() {
  "$CH" --headless=new --disable-gpu --hide-scrollbars --window-size=1200,700 \
    --user-data-dir="$TMP/ft$1" --virtual-time-budget=2500 --dump-dom \
    "file://$PWD/app/pelican.html#$2" > "$TMP/ft$1.html" 2>/dev/null
}
foot parked "t=3"
foot riding "rate=150&t=3"
python3 - "$TMP/ftparked.html" "$TMP/ftriding.html" <<'PY'
import re, sys
def grab(path):
    dom = open(path, encoding='utf-8').read()
    t = re.search(r'id="footNear" transform="translate\(([-\d.]+) ([-\d.]+)\)', dom)
    shadow = re.search(r'id="footShadow"[^>]*opacity="([\d.]+)"', dom)
    pedal = re.search(r'id="pedalA" transform="translate\(([-\d.]+) ([-\d.]+)\)', dom)
    return float(t.group(1)), float(t.group(2)), float(shadow.group(1)), \
           float(pedal.group(1)), float(pedal.group(2))

px, py, shadow, _, _ = grab(sys.argv[1])
rx, ry, rshadow, ax, ay = grab(sys.argv[2])
assert py > 495, f'停下来脚还挂在踏板上：y={py:.1f}'
assert shadow > .1, f'落地却没有接触阴影：opacity={shadow}'
assert abs(rx - ax) < 1 and abs(ry - (ay - 9)) < 1, \
    f'骑起来脚没回到踏板：foot=({rx:.1f},{ry:.1f}) pedal=({ax:.1f},{ay:.1f})'
assert rshadow < .01, f'骑起来还留着落地阴影：opacity={rshadow}'
PY

echo "· 换车：一脚油门直接上摩托，中间不闪电车"
burst() {
  "$CH" --headless=new --disable-gpu --hide-scrollbars --window-size=1200,700 \
    --user-data-dir="$TMP/bu$1" --virtual-time-budget=2000 --dump-dom \
    "file://$PWD/app/pelican.html#rate=1500&t=$1" > "$TMP/bu$1.html" 2>/dev/null
}
burst 0.5
burst 0.9
python3 - "$TMP/bu0.5.html" "$TMP/bu0.9.html" <<'PY'
import re, sys
def shown(path):
    dom = open(path, encoding='utf-8').read()
    out = {}
    for vid in ('bike', 'ebike', 'moto'):
        m = re.search(rf'id="{vid}" style="([^"]*)"', dom)
        # no style attribute at all means visible: display:'' drops it
        out[vid] = m is None or 'display:none' not in m.group(1).replace(' ', '')
    return out
mid, top = shown(sys.argv[1]), shown(sys.argv[2])
assert mid['ebike'] is False, '速度经过电车档时闪了一下电车，应该直接上摩托'
assert mid['bike'] is True, '还没到摩托的速度，自行车却已经换掉了'
assert top['moto'] is True and top['ebike'] is False, f'高速下不是摩托：{top}'
PY

echo "· 车灯：夜里照在前进方向的沙面上"
python3 - "$TMP/phday.html" "$TMP/phnight.html" <<'PY'
import re, sys
def grab(path):
    dom = open(path, encoding='utf-8').read()
    beam = re.search(r'id="beam"[^>]*opacity="0"[^>]*?style="([^"]*)"', dom) or \
           re.search(r'id="beam"[^>]*style="([^"]*)"', dom)
    d = re.search(r'id="beam"[^>]* d="([^"]+)"', dom).group(1)
    lamp = re.search(r'id="lamp" cx="([\d.]+)" cy="([\d.]+)"', dom)
    return beam.group(1), d, float(lamp.group(1)), float(lamp.group(2))
day, night = grab(sys.argv[1]), grab(sys.argv[2])
assert 'opacity:0' in day[0].replace(' ', ''), f'白天车灯还亮着：{day[0]!r}'
assert 'opacity:1' in night[0].replace(' ', ''), f'夜里车灯没亮：{night[0]!r}'
pts = [tuple(map(float, p.split())) for p in re.findall(r'([\d.]+ [\d.]+)', night[1])]
assert len(pts) == 3, f'光锥应该是灯头加两个落地点：{night[1]}'
apex, a, b = pts
for gx, gy in (a, b):
    assert gy >= 520, f'光斑没落到沙面上：y={gy}'
    assert gx > apex[0] + 80, f'光锥没朝前（右）：灯头 x={apex[0]}，落点 x={gx}'
_, _, lx, ly = night
assert lx > 900 and ly >= 520, f'光斑位置不对，应该在车前的地上：({lx}, {ly})'
PY

echo "  ✓ 全过"
