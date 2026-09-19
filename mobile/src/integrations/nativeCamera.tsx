import { useEffect } from 'react';
import { Platform, View } from 'react-native';
import { requireOptionalNativeModule } from 'expo';
import type { CameraProps, IntegrationKit } from './contracts';
import type { SignloopCamera as CameraView } from '../../modules/signloop-camera';
import { demoKit } from './demo';
import { framingFromCamera } from './cameraStatus';

const NativeCamera: typeof CameraView | null = Platform.OS === 'ios' && requireOptionalNativeModule('SignloopCamera')
  ? require('../../modules/signloop-camera').SignloopCamera : null;

function Camera({ active, captureId, onFraming, style }: CameraProps) {
  useEffect(() => {
    if (!NativeCamera && active) onFraming('camera-unavailable', captureId);
  }, [active, captureId, onFraming]);
  if (!NativeCamera) return <View style={style} />;
  return <NativeCamera active={active} captureId={captureId} showSkeleton style={style}
    accessibilityElementsHidden importantForAccessibility="no-hide-descendants"
    onStatus={({ nativeEvent }) => {
      const framing = framingFromCamera(nativeEvent, active, captureId);
      if (framing) onFraming(framing, captureId);
    }} />;
}

export const cameraKit: IntegrationKit = {
  mode: 'camera', Camera, Avatar: demoKit.Avatar,
  // Camera readiness cannot manufacture English. Wire accepted phrases here next.
  translation: { start: () => () => {} },
  voice: { speak: async () => { throw new Error('Voice is not connected yet'); } },
};
