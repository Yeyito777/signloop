import { useEffect, useRef, type RefObject } from 'react';
import { Group, Mesh, MeshBasicMaterial, OrthographicCamera } from 'three';
import { useFrame, useThree } from './GooseCanvas';
import { colors, motion } from './settings';
import { advanceTime, composePose, stillPose, stepPose, type GooseActivity, type GooseEmotion, type GoosePose } from './motion';
import { levelAt, type LipSync } from '../../voice/envelope.ts';
import { gestureAt } from '../../voice/gestures.ts';

type Vec3 = [number, number, number];
type PebbleProps = {
  color: string;
  position?: Vec3;
  scale: Vec3;
  rotation?: Vec3;
  glossy?: boolean;
};

// Every part is a smooth, scaled sphere. No model downloads or texture assets.
function Pebble({ color, position, scale, rotation, glossy = false }: PebbleProps) {
  return (
    <mesh position={position} scale={scale} rotation={rotation}>
      <sphereGeometry args={[1, 32, 24]} />
      <meshStandardMaterial color={color} roughness={glossy ? 0.18 : 0.83} metalness={0} />
    </mesh>
  );
}

function Eye({ side, blinkRef }: { side: number; blinkRef: RefObject<Group | null> }) {
  return (
    <group position={[side * 0.335, 0.08, 0.604]} rotation={[0, side * 0.18, 0]}>
      <group ref={blinkRef}>
        <Pebble color={colors.eyes} scale={[0.113, 0.148, 0.077]} glossy />
        <mesh position={[-0.027, 0.052, 0.066]} scale={[0.032, 0.04, 0.018]}>
          <sphereGeometry args={[1, 16, 12]} />
          <meshBasicMaterial color={colors.highlight} />
        </mesh>
        <mesh position={[0.033, -0.034, 0.073]} scale={[0.013, 0.016, 0.008]}>
          <sphereGeometry args={[1, 12, 8]} />
          <meshBasicMaterial color={colors.highlight} />
        </mesh>
      </group>
    </group>
  );
}

function Goose({ animate, reducedMotion, activity, emotion, lipSync }: {
  animate: boolean;
  reducedMotion: boolean;
  activity: GooseActivity;
  emotion?: GooseEmotion;
  lipSync?: RefObject<LipSync>;
}) {
  const root = useRef<Group>(null);
  const body = useRef<Group>(null);
  const head = useRef<Group>(null);
  const leftWing = useRef<Group>(null);
  const rightWing = useRef<Group>(null);
  const leftEye = useRef<Group>(null);
  const rightEye = useRef<Group>(null);
  const upperBeak = useRef<Group>(null);
  const lowerBeak = useRef<Group>(null);
  const steamPuffs = useRef<(Mesh | null)[]>([null, null, null, null, null, null]);
  const tearDrops = useRef<(Mesh | null)[]>([null, null, null, null]);
  const time = useRef(0);
  const displayed = useRef<GoosePose>(stillPose(emotion));
  const invalidate = useThree(state => state.invalidate);

  function applyPose(pose: GoosePose) {
    if (root.current) {
      root.current.position.y = pose.bob;
      root.current.rotation.y = pose.bodyYaw;
    }
    if (body.current) body.current.scale.set(1 + (pose.breath - 1) * 0.5, pose.breath, pose.breath);
    if (head.current) {
      head.current.rotation.x = pose.pitch;
      head.current.rotation.y = pose.yaw;
      head.current.rotation.z = pose.tilt;
    }
    if (leftWing.current) {
      leftWing.current.rotation.set(pose.leftWingPitch, pose.leftWingYaw, -0.14 - pose.wing - pose.leftWing);
    }
    if (rightWing.current) {
      rightWing.current.rotation.set(pose.rightWingPitch, pose.rightWingYaw, 0.14 + pose.wing + pose.rightWing);
    }
    if (leftEye.current) leftEye.current.scale.y = pose.eyes;
    if (rightEye.current) rightEye.current.scale.y = pose.eyes;
    if (upperBeak.current) upperBeak.current.position.y = -0.16 + pose.beak * 0.045;
    if (lowerBeak.current) lowerBeak.current.position.y = -0.278 - pose.beak * 0.055;
  }

  function applyEffects(clock: number, current?: GooseEmotion) {
    const steaming = current === 'anger';
    steamPuffs.current.forEach((mesh, i) => {
      if (!mesh) return;
      mesh.visible = steaming;
      if (!steaming) return;
      const phase = (clock / 1.35 + i * 0.17) % 1;
      const side = i % 2 === 0 ? -1 : 1;
      mesh.position.set(side * (0.42 + phase * 0.16), 0.52 + phase * 0.5, 0.08 + (i % 3) * 0.02);
      const size = 0.085 + phase * 0.09;
      mesh.scale.set(size * 1.2, size, size * 1.2);
      (mesh.material as MeshBasicMaterial).opacity = (1 - phase) * 0.7;
    });

    const crying = current === 'sadness';
    tearDrops.current.forEach((mesh, i) => {
      if (!mesh) return;
      mesh.visible = crying;
      if (!crying) return;
      const phase = (clock / 1.55 + i * 0.28) % 1;
      const side = i % 2 === 0 ? -1 : 1;
      mesh.position.set(side * (0.36 + phase * 0.05), -0.02 - phase * 0.38, 0.78);
      const size = 0.06 + (1 - phase) * 0.02;
      mesh.scale.set(size * 0.65, size * 1.45, size * 0.65);
      (mesh.material as MeshBasicMaterial).opacity = (1 - phase) * 0.95;
    });
  }

  useEffect(() => {
    if (reducedMotion) {
      time.current = 0;
      displayed.current = stillPose(emotion);
      applyPose(displayed.current);
    }
    applyEffects(time.current, emotion);
    invalidate();
  }, [reducedMotion, activity, emotion, invalidate]);

  useFrame((_, delta) => {
    if (!animate) return;
    time.current = advanceTime(time.current, delta, true);
    const clock = lipSync?.current?.currentTime() ?? 0;
    const speakingLevel = activity === 'speaking' ? levelAt(lipSync?.current?.envelope, clock) : undefined;
    const gesture = activity === 'speaking' ? gestureAt(lipSync?.current?.gestures, clock) : undefined;
    const blend = speakingLevel === undefined && !gesture ? motion.blendSeconds : motion.lipSyncSeconds;
    displayed.current = stepPose(displayed.current, composePose(time.current, activity, emotion, speakingLevel, gesture), delta, blend);
    applyPose(displayed.current);
    applyEffects(time.current, emotion);
  });

  return (
    <group rotation={[0, -0.1, 0]}>
      {/* Chunky feet stay planted beneath the tiny body bob. */}
      {[-1, 1].map(side => (
        <group key={side} position={[side * 0.43, 0.14, 0.21]} rotation={[0, side * -0.15, 0]}>
          <Pebble color={colors.beakAndFeet} scale={[0.29, 0.14, 0.43]} />
          <Pebble color={colors.beakAndFeet} position={[0, 0.17, -0.14]} scale={[0.13, 0.24, 0.15]} />
        </group>
      ))}
      <group ref={root}>
        <group ref={body} position={[0, 1.2, 0]}>
          <Pebble color={colors.body} scale={[0.96, 1.02, 0.75]} />
          <Pebble color={colors.belly} position={[0, -0.05, 0.56]} scale={[0.73, 0.79, 0.26]} />
          <group ref={leftWing} position={[-0.81, 0.36, 0.04]} rotation={[0, 0, -0.14]}>
            <Pebble color={colors.wings} position={[-0.08, -0.36, 0.02]} scale={[0.26, 0.59, 0.39]} rotation={[0.1, 0, 0]} />
          </group>
          <group ref={rightWing} position={[0.81, 0.36, 0.04]} rotation={[0, 0, 0.14]}>
            <Pebble color={colors.wings} position={[0.08, -0.36, 0.02]} scale={[0.26, 0.59, 0.39]} rotation={[0.1, 0, 0]} />
          </group>
        </group>
        <Pebble color={colors.neck} position={[0, 2.14, 0.02]} scale={[0.38, 0.68, 0.36]} />
        <group ref={head} position={[0, 2.9, 0.07]}>
          <Pebble color={colors.face} scale={[0.77, 0.72, 0.66]} />
          {[-1, 1].map(side => (
            <Pebble key={side} color={colors.cheeks} position={[side * 0.46, -0.22, 0.46]} scale={[0.31, 0.27, 0.17]} rotation={[0, side * 0.5, side * -0.15]} />
          ))}
          {/* Scale each complete eye around its own center, including its highlights. */}
          <Eye side={-1} blinkRef={leftEye} />
          <Eye side={1} blinkRef={rightEye} />
          {[0, 1, 2, 3, 4, 5].map(i => (
            <mesh key={`steam-${i}`} ref={node => { steamPuffs.current[i] = node; }} visible={false}>
              <sphereGeometry args={[1, 12, 10]} />
              <meshBasicMaterial color={colors.steam} transparent opacity={0} depthWrite={false} />
            </mesh>
          ))}
          {[0, 1, 2, 3].map(i => (
            <mesh key={`tear-${i}`} ref={node => { tearDrops.current[i] = node; }} visible={false}>
              <sphereGeometry args={[1, 12, 10]} />
              <meshBasicMaterial color={colors.tear} transparent opacity={0} depthWrite={false} />
            </mesh>
          ))}
          <group ref={upperBeak} name="upper-beak" position={[0, -0.16, 0.7]}>
            <Pebble color={colors.beakAndFeet} scale={[0.245, 0.125, 0.29]} />
          </group>
          <group ref={lowerBeak} name="lower-beak" position={[0, -0.278, 0.695]}>
            <Pebble color={colors.beakAndFeet} scale={[0.21, 0.067, 0.24]} />
          </group>
          <group position={[0, 0.62, -0.03]} rotation={[0.05, 0, -0.2]}>
            <Pebble color={colors.face} position={[-0.07, 0.12, 0]} scale={[0.09, 0.24, 0.1]} rotation={[0, 0, 0.25]} />
            <Pebble color={colors.face} position={[0.075, 0.08, 0]} scale={[0.085, 0.2, 0.09]} rotation={[0, 0, -0.28]} />
          </group>
        </group>
      </group>
    </group>
  );
}

export function GooseScene(props: {
  animate: boolean;
  reducedMotion: boolean;
  activity: GooseActivity;
  emotion?: GooseEmotion;
  lipSync?: RefObject<LipSync>;
}) {
  const { camera, size, invalidate } = useThree();
  useEffect(() => {
    const orthographicCamera = camera as OrthographicCamera;
    orthographicCamera.zoom = Math.min(size.width / 2.8, size.height / 4.2);
    orthographicCamera.lookAt(0, 1.93, 0);
    orthographicCamera.updateProjectionMatrix();
    invalidate();
  }, [camera, size.width, size.height, invalidate]);

  return (
    <>
      <hemisphereLight args={['#FFF9EF', '#B5A38C', 1.5]} />
      <directionalLight position={[-3, 5, 7]} color="#FFF8EC" intensity={2.5} />
      <directionalLight position={[4, 3, 5]} color="#EAF0FF" intensity={1} />
      {/* Layered translucent disks give a soft contact shadow without a costly shadow map. */}
      <group rotation={[-Math.PI / 2, 0, 0]} position={[0, 0.004, 0]} scale={[1, 0.64, 1]}>
        {Array.from({ length: 24 }, (_, i) => (
          <mesh key={i} position={[0, 0, i * 0.0002]}>
            <circleGeometry args={[1.2 - i * 0.031, 64]} />
            <meshBasicMaterial color={colors.shadow} transparent opacity={0.013} depthWrite={false} />
          </mesh>
        ))}
      </group>
      <Goose {...props} />
    </>
  );
}
