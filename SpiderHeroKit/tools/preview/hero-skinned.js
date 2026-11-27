// Skinned hero (GLB exported by tools/character/export.py) driven by Motor6D.Transform poses.
// Bone rest frames equal the Motor6D joint frames, so: bone local = rest * Transform.
import * as THREE from 'three';
import { GLTFLoader } from 'three/addons/loaders/GLTFLoader.js';

const JOINT_TO_BONE = { Root: 'LowerTorso', Waist: 'UpperTorso', Neck: 'Head' };
for (const s of ['Right', 'Left']) {
  Object.assign(JOINT_TO_BONE, {
    [s + 'Shoulder']: s + 'UpperArm', [s + 'Elbow']: s + 'LowerArm', [s + 'Wrist']: s + 'Hand',
    [s + 'Hip']: s + 'UpperLeg', [s + 'Knee']: s + 'LowerLeg', [s + 'Ankle']: s + 'Foot',
  });
}

export async function loadHero(url) {
  const gltf = await new GLTFLoader().loadAsync(url);
  const root = gltf.scene;
  const bones = {};
  root.traverse((o) => {
    if (o.isBone) bones[o.name] = o;
    if (o.isMesh) {
      o.castShadow = true;
      o.receiveShadow = true;
      o.frustumCulled = false;
      if (o.material) {
        o.material.envMapIntensity = 0.9;
        if (o.name.startsWith('HumanoidRootPart')) o.visible = false;
      }
    }
  });
  const rest = {};
  for (const [n, b] of Object.entries(bones)) rest[n] = { p: b.position.clone(), q: b.quaternion.clone() };
  root.updateMatrixWorld(true);
  const hrpRest = bones.HumanoidRootNode.matrixWorld.clone();
  const wrapper = new THREE.Group();
  wrapper.add(root);
  wrapper.matrixAutoUpdate = false;
  return { wrapper, root, bones, rest, hrpRestInv: hrpRest.clone().invert() };
}

const _q = new THREE.Quaternion();
const _v = new THREE.Vector3();
const _m = new THREE.Matrix4();

export function cfToMatrix(a, out = new THREE.Matrix4()) {
  out.set(a[3], a[4], a[5], a[0], a[6], a[7], a[8], a[1], a[9], a[10], a[11], a[2], 0, 0, 0, 1);
  return out;
}

// pose: { rootCF: [12], joints: { JointName: [qx,qy,qz,qw,px,py,pz] } }
export function applyHeroPose(hero, pose) {
  for (const [n, r] of Object.entries(hero.rest)) {
    hero.bones[n].position.copy(r.p);
    hero.bones[n].quaternion.copy(r.q);
  }
  if (pose && pose.joints) {
    for (const [joint, t] of Object.entries(pose.joints)) {
      const bn = JOINT_TO_BONE[joint] || joint;
      const b = hero.bones[bn];
      if (!b) continue;
      const r = hero.rest[bn];
      _q.set(t[0], t[1], t[2], t[3]);
      b.quaternion.copy(r.q).multiply(_q);
      _v.set(t[4] || 0, t[5] || 0, t[6] || 0).applyQuaternion(r.q);
      b.position.copy(r.p).add(_v);
    }
  }
  const rootM = pose && pose.rootCF ? cfToMatrix(pose.rootCF) : new THREE.Matrix4().makeTranslation(0, 3.3, 0);
  hero.wrapper.matrix.copy(rootM).multiply(hero.hrpRestInv);
  hero.wrapper.matrixWorldNeedsUpdate = true;
  hero.wrapper.updateMatrixWorld(true);
}

// world position of a hand's web attachment point (palm, slightly toward the fingers)
export function webAttachPoint(hero, side) {
  const hand = hero.bones[side + 'Hand'];
  const local = new THREE.Vector3(side === 'Right' ? -0.07 : 0.07, -0.16, -0.005);
  return local.applyMatrix4(hand.matrixWorld);
}
