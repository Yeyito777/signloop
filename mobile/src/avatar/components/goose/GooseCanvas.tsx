import { useRef, type ComponentProps } from 'react';
import { Canvas as NativeCanvas, useFrame } from '@react-three/fiber/native';
export { useFrame, useThree } from '@react-three/fiber/native';

/** Synchronize native surface setup and initial uploads before steady rendering. */
function NativeStartup() {
  const frames = useRef(0);
  useFrame(({ gl, invalidate }) => {
    if (frames.current >= 3) return;
    const context = gl.getContext() as WebGLRenderingContext & { flushEXP: () => void };
    context.flushEXP();
    frames.current += 1;
    // Also finish startup when Reduce Motion selects on-demand rendering.
    if (frames.current < 3) invalidate();
  });
  return null;
}

// Expo GL's asynchronous setup can otherwise leave this transparent surface blank.
// Drain its startup work for three frames only; normal animation never blocks on GL.
export function Canvas({ children, ...props }: ComponentProps<typeof NativeCanvas>) {
  return <NativeCanvas {...props}><NativeStartup />{children}</NativeCanvas>;
}
