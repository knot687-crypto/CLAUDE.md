// Shared three.js stage for SpiderHeroKit previews (QA screenshots and the showcase page):
// sky-tinted background with fog, hemisphere + key/fill/rim lights, shadowed ground disc.
import * as THREE from 'three';

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
