import { useEffect } from 'react';
import { Platform, View } from 'react-native';
import { requireOptionalNativeModule } from 'expo';
import type { CameraProps, IntegrationKit } from './contracts';
import type { SignloopCamera as CameraView } from '../../modules/signloop-camera';
import { GooseAvatar } from './GooseAvatar';
import { gooseVoice } from './voice';
import { candidateFromPrediction } from './localSign';
import { cameraAvailability, framingFromCamera } from './cameraStatus';

const nativeModule = Platform.OS === 'ios'
  ? requireOptionalNativeModule<{ recognitionVersion?: number }>('SignloopCamera') : null;
const unavailable = cameraAvailability(nativeModule);
const NativeCamera: typeof CameraView | null = unavailable === null
  ? require('../../modules/signloop-camera').SignloopCamera : null;

function Camera({ active, captureId, onFraming, onTranslation, onExpression, style }: CameraProps) {
  useEffect(() => {
    if (unavailable && active) onFraming(unavailable, captureId);
  }, [active, captureId, onFraming]);
  if (!NativeCamera) return <View style={style} />;
  return <NativeCamera active={active} captureId={captureId} showSkeleton style={style}
    accessibilityElementsHidden importantForAccessibility="no-hide-descendants"
    onExpression={({ nativeEvent }) => { if (active && nativeEvent.captureId === captureId) onExpression(nativeEvent); }}
    onPrediction={({ nativeEvent }) => {
      const event = candidateFromPrediction(nativeEvent, active, captureId);
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
