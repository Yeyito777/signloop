import { useRef, useState, type ComponentProps } from 'react';
import { StyleSheet, View } from 'react-native';
import { Canvas as NativeCanvas, useFrame } from '@react-three/fiber/native';
import { SoftwarePreviewContext } from './renderQuality';
export { useFrame, useThree } from '@react-three/fiber/native';

/** Simulator OpenGL can be CPU-only. Do not enqueue 60 expensive draws per second. */
function SoftwareFrames() {
  const elapsed = useRef(Infinity);
  useFrame(({ gl, scene, camera, frameloop }, delta) => {
    elapsed.current += delta;
    if (frameloop === 'always' && elapsed.current < 1 / 12) return;
    elapsed.current = 0;
    // Fiber's native renderer already presents the frame with endFrameEXP().
    gl.render(scene, camera);
  }, 1);
  return null;
}

export function Canvas({ children, style, onCreated, ...props }: ComponentProps<typeof NativeCanvas>) {
  const [software, setSoftware] = useState(false);
  const [size, setSize] = useState({ width: 0, height: 0 });
  // Keep the stage's layout unchanged; only lower the software drawing resolution.
  const scale = software ? 3 : 1;
  return <View style={[styles.container, style]} onLayout={({ nativeEvent }) => setSize(nativeEvent.layout)}>
    {size.width > 0 && size.height > 0 && <NativeCanvas {...props}
      style={{ position: 'absolute', width: size.width / scale, height: size.height / scale,
        left: size.width * (1 - 1 / scale) / 2, top: size.height * (1 - 1 / scale) / 2,
        transform: [{ scale }] }}
      onCreated={state => {
        const context = state.gl.getContext();
        setSoftware(/software|llvmpipe|swiftshader/i.test(String(context.getParameter(context.RENDERER))));
        onCreated?.(state);
      }}>
      <SoftwarePreviewContext.Provider value={software}>
        {software && <SoftwareFrames />}
        {children}
      </SoftwarePreviewContext.Provider>
    </NativeCanvas>}
  </View>;
}

const styles = StyleSheet.create({ container: { flex: 1 } });
