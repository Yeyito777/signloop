import { useEffect } from 'react';
import { Platform, View } from 'react-native';
import { requireOptionalNativeModule } from 'expo';
import type { CameraProps, IntegrationKit } from './contracts';
import type { SignloopCamera as CameraView } from '../../modules/signloop-camera';
import { GooseAvatar } from './GooseAvatar';
import { gooseVoice } from './voice';
import { candidateFromSign } from './localSign';
import { framingFromCamera } from './cameraStatus';

const NativeCamera: typeof CameraView | null = Platform.OS === 'ios' && requireOptionalNativeModule('SignloopCamera')
  ? require('../../modules/signloop-camera').SignloopCamera : null;

function Camera({ active, captureId, onFraming, onTranslation, style }: CameraProps) {
  useEffect(() => {
    if (!NativeCamera && active) onFraming('camera-unavailable', captureId);
  }, [active, captureId, onFraming]);
  if (!NativeCamera) return <View style={style} />;
  return <NativeCamera active={active} captureId={captureId} showSkeleton style={style}
    accessibilityElementsHidden importantForAccessibility="no-hide-descendants"
    onSign={({ nativeEvent }) => {
      const event = candidateFromSign(nativeEvent, active, captureId);
      if (event) onTranslation(event, captureId);
    }}
    onStatus={({ nativeEvent }) => {
      const framing = framingFromCamera(nativeEvent, active, captureId);
      if (framing) onFraming(framing, captureId);
    }} />;
}

export const cameraKit: IntegrationKit = {
  mode: 'live', Camera, Avatar: GooseAvatar,
  // Local estimates arrive from the camera and require explicit user confirmation.
  translation: { start: () => () => {} },
  voice: gooseVoice,
};
