#!/bin/bash
# Full character pipeline: sculpt -> retopo -> rig -> bakes -> suit textures -> final normals.
set -e
cd "$(dirname "$0")"
PY=${PY:-python3}
$PY sculpt.py 0.006
$PY retopo.py 60000 36000
$PY rig.py
$PY bake_maps.py 2048
$PY bake_ao.py 2048
$PY suit.py
$PY finalize.py 2048
$PY - <<'PYEOF'
import bpy, os
p = os.path.abspath("out/character_final.blend")
bpy.ops.wm.open_mainfile(filepath=p)
for n in ("High", "HighRef"):
    if n in bpy.data.objects:
        bpy.data.objects.remove(bpy.data.objects[n])
bpy.ops.outliner.orphans_purge(do_recursive=True)
bpy.ops.wm.save_as_mainfile(filepath=p)
PYEOF
echo "character pipeline complete"
