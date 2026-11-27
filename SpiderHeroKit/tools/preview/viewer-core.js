// Shared three.js renderer for SpiderHeroKit previews (QA screenshots and the showcase page).
// Reconstructs the Roblox rig exactly: parts welded to segments, segments driven by Motor6D FK:
//   Part1.CFrame = Part0.CFrame * C0 * Transform * C1:Inverse()
import * as THREE from 'three';

export function cfToMatrix(a, out = new THREE.Matrix4()) {
  // Roblox CFrame components: x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22
  out.set(a[3], a[4], a[5], a[0], a[6], a[7], a[8], a[1], a[9], a[10], a[11], a[2], 0, 0, 0, 1);
  return out;
}

const MATERIAL_PRESETS = {
  SmoothPlastic: { roughness: 0.5, metalness: 0.0 },
  Plastic: { roughness: 0.6, metalness: 0.0 },
  Metal: { roughness: 0.32, metalness: 0.85 },
  Neon: { roughness: 0.5, metalness: 0.0, emissive: true },
  Glass: { roughness: 0.08, metalness: 0.1 },
  Fabric: { roughness: 0.85, metalness: 0.0 },
};

const geoCache = {};
function geometryFor(shape) {
  if (geoCache[shape]) return geoCache[shape];
  let g;
  if (shape === 'ellipsoid' || shape === 'ball') {
    g = new THREE.SphereGeometry(0.5, 40, 24);
  } else if (shape === 'cylinder') {
    g = new THREE.CylinderGeometry(0.5, 0.5, 1, 20, 1);
    g.rotateZ(-Math.PI / 2); // Roblox cylinders run along X
  } else {
    g = new THREE.BoxGeometry(1, 1, 1);
  }
  geoCache[shape] = g;
  return g;
}

const matCache = new Map();
function materialFor(p) {
  const key = `${p.color.join(',')}|${p.material}|${p.reflectance}`;
  if (matCache.has(key)) return matCache.get(key);
  const preset = MATERIAL_PRESETS[p.material] || MATERIAL_PRESETS.SmoothPlastic;
  const color = new THREE.Color().setRGB(p.color[0], p.color[1], p.color[2], THREE.SRGBColorSpace);
  let roughness = preset.roughness;
  let envMapIntensity = 1.0;
  if (p.reflectance > 0) {
    roughness = Math.max(0.06, roughness - p.reflectance * 1.6);
    envMapIntensity = 1 + p.reflectance * 4;
  }
  const m = new THREE.MeshStandardMaterial({ color, roughness, metalness: preset.metalness, envMapIntensity });
  if (preset.emissive) { m.emissive = color; m.emissiveIntensity = 1.2; }
  matCache.set(key, m);
  return m;
}

export function buildCharacter(model) {
  const root = new THREE.Group();
  root.name = 'Character';
  const segGroups = {};
  for (const s of model.segments) {
    const g = new THREE.Group();
    g.name = s.name;
    g.matrixAutoUpdate = false;
    root.add(g);
    segGroups[s.name] = g;
  }
  const tmp = new THREE.Matrix4();
  for (const p of model.parts) {
    const mesh = new THREE.Mesh(geometryFor(p.shape), materialFor(p));
    let sx = p.size[0], sy = p.size[1], sz = p.size[2];
    if (p.shape === 'cylinder') { const d = Math.min(sy, sz); sy = d; sz = d; }
    if (p.shape === 'ball') { const d = Math.min(sx, sy, sz); sx = sy = sz = d; }
    cfToMatrix(p.cf, tmp);
    mesh.matrixAutoUpdate = false;
    mesh.matrix.copy(tmp).multiply(new THREE.Matrix4().makeScale(sx, sy, sz));
    mesh.castShadow = !!p.shadow || p.shape === 'ellipsoid';
    mesh.receiveShadow = true;
    segGroups[p.segment].add(mesh);
  }
  // joint table
  const joints = model.joints.map((j) => ({
    name: j.name,
    part0: j.part0,
    part1: j.part1,
    c0: cfToMatrix(j.c0),
    c1inv: cfToMatrix(j.c1).invert(),
  }));
  const jointIndex = {};
  joints.forEach((j, i) => { jointIndex[j.name] = i; });
  return { root, segGroups, joints, jointIndex, model };
}

const _q = new THREE.Quaternion();
const _p = new THREE.Vector3();
const _one = new THREE.Vector3(1, 1, 1);
const _t = new THREE.Matrix4();

// pose: { rootCF: [12], joints: { name: [qx,qy,qz,qw,px,py,pz] } } (missing joints = identity)
export function applyPose(ch, pose) {
  const world = {};
  const rootM = pose && pose.rootCF ? cfToMatrix(pose.rootCF) : new THREE.Matrix4().makeTranslation(...ch.model.rootCenter);
  world.HumanoidRootPart = rootM;
  ch.segGroups.HumanoidRootPart.matrix.copy(rootM);
  for (const j of ch.joints) {
    const parent = world[j.part0];
    const tr = pose && pose.joints ? pose.joints[j.name] : null;
    if (tr) {
      _q.set(tr[0], tr[1], tr[2], tr[3]);
      _p.set(tr[4] || 0, tr[5] || 0, tr[6] || 0);
      _t.compose(_p, _q, _one);
    } else {
      _t.identity();
    }
    const m = new THREE.Matrix4().copy(parent).multiply(j.c0).multiply(_t).multiply(j.c1inv);
    world[j.part1] = m;
    ch.segGroups[j.part1].matrix.copy(m);
  }
  for (const g of Object.values(ch.segGroups)) g.matrixWorldNeedsUpdate = true;
  return world;
}

export function makeStage(renderer, opts = {}) {
  const scene = new THREE.Scene();
  const bg = opts.background ?? 0x1b2230;
  scene.background = new THREE.Color(bg);
  scene.fog = new THREE.Fog(bg, 60, 260);

  const hemi = new THREE.HemisphereLight(0xc9d8ff, 0x3a2f2a, 0.55);
  scene.add(hemi);
  const key = new THREE.DirectionalLight(0xfff1de, 2.6);
  key.position.set(-6, 11, -8);
  key.castShadow = true;
  key.shadow.mapSize.set(2048, 2048);
  key.shadow.camera.left = -6; key.shadow.camera.right = 6;
  key.shadow.camera.top = 8; key.shadow.camera.bottom = -2;
  key.shadow.camera.near = 1; key.shadow.camera.far = 40;
  key.shadow.bias = -0.0004;
  key.shadow.normalBias = 0.02;
  key.shadow.radius = 3;
  scene.add(key);
  scene.add(key.target);
  const fill = new THREE.DirectionalLight(0x9fb8ff, 0.7);
  fill.position.set(8, 5, -4);
  scene.add(fill);
  const rim = new THREE.DirectionalLight(0xffffff, 1.6);
  rim.position.set(2, 7, 10);
  scene.add(rim);

  if (opts.ground !== false) {
    const ground = new THREE.Mesh(
      new THREE.CircleGeometry(4000, 96),
      new THREE.MeshStandardMaterial({ color: opts.groundColor ?? 0x3b4250, roughness: 0.9, metalness: 0 })
    );
    ground.rotation.x = -Math.PI / 2;
    ground.receiveShadow = true;
    scene.add(ground);
  }
  return { scene, key, fill, rim, hemi };
}
