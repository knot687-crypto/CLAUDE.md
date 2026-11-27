# Foot-slide QA on a baked scenario: FK the feet from the frames and measure planted-foot drift.
#   python3 tools/analyze_slide.py tools/preview/out/clip_scn_ground.json
import json, sys, math
import numpy as np
d = json.load(open(sys.argv[1]))
m = json.load(open('tools/preview/out/model_view.json'))
def cf(a):
    M = np.eye(4); M[0,3],M[1,3],M[2,3] = a[0],a[1],a[2]
    M[0,:3] = a[3:6]; M[1,:3] = a[6:9]; M[2,:3] = a[9:12]; return M
def tr(q):
    x,y,z,w,px,py,pz = q
    M = np.eye(4)
    M[:3,:3] = [[1-2*(y*y+z*z), 2*(x*y-z*w), 2*(x*z+y*w)],[2*(x*y+z*w), 1-2*(x*x+z*z), 2*(y*z-x*w)],[2*(x*z-y*w), 2*(y*z+x*w), 1-2*(x*x+y*y)]]
    M[:3,3] = [px,py,pz]; return M
joints = [(j['name'], j['part0'], j['part1'], cf(j['c0']), np.linalg.inv(cf(j['c1']))) for j in m['joints']]
soles = [np.array([0,-0.135,0.36,1]), np.array([0,-0.135,-0.25,1]), np.array([0,-0.1,-0.42,1])]
fps = d['fps']
prev = {}
slides = []; minY = 9; worst = (0, None)
for i, f in enumerate(d['frames']):
    W = {'HumanoidRootPart': cf(f['rootCF'])}
    for name, p0, p1, c0, c1i in joints:
        if p0 in W: W[p1] = W[p0] @ c0 @ tr(f['joints'][name]) @ c1i
    for side in ('Right', 'Left'):
        pts = [W[side+'Foot'] @ s for s in soles]
        low = min(pts, key=lambda p: p[1])
        minY = min(minY, low[1]) if f['state']=='Ground' else minY
        if f['state'] == 'Ground' and low[1] < 0.06 and side in prev and prev[side][1] < 0.06 and f.get('oneShot') is None:
            dv = math.hypot(low[0]-prev[side][0], low[2]-prev[side][2]) * fps
            slides.append(dv)
            if dv > worst[0]: worst = (dv, (i, side, round(f['t'],2)))
        prev[side] = low
slides.sort()
n = len(slides)
print(f"planted samples {n}: median slide {slides[n//2]:.2f} studs/s, p90 {slides[int(n*0.9)]:.2f}, max {worst[0]:.2f} at {worst[1]}; min sole y on ground {minY:.3f}")
