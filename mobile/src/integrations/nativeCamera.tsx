import { useEffect } from 'react';
import { Platform, View } from 'react-native';
import { requireOptionalNativeModule } from 'expo';
import type { CameraProps, IntegrationKit } from './contracts';
import type { SignloopCamera as CameraView } from '../../modules/signloop-camera';
import { GooseAvatar } from './GooseAvatar';
import { gooseVoice } from './voice';
import { translationFromPrediction } from './localSign';
import { cameraAvailability, framingFromCamera } from './cameraStatus';

const nativeModule = Platform.OS === 'ios'
  ? requireOptionalNativeModule<{ recognitionVersion?: number }>('SignloopCamera') : null;
const unavailable = cameraAvailability(nativeModule);
const NativeCamera: typeof CameraView | null = unavailable === null
  ? require('../../modules/signloop-camera').SignloopCamera : null;

function Camera({ active, captureId, onFraming, onTranslation, onExpression, style, recognitionMode = 'signs', detectionSettings, onDetection }: CameraProps) {
  useEffect(() => {
    if (unavailable && active) onFraming(unavailable, captureId);
  }, [active, captureId, onFraming]);
  if (!NativeCamera) return <View style={style} />;
  return <NativeCamera active={active} captureId={captureId} recognitionMode={recognitionMode}
    showSkeleton={detectionSettings?.showSkeleton ?? true} showPose={detectionSettings?.showPose ?? true}
    trackFace={detectionSettings?.trackFace ?? true} style={style}
    accessibilityElementsHidden importantForAccessibility="no-hide-descendants"
    onExpression={({ nativeEvent }) => { if (active && nativeEvent.captureId === captureId) onExpression(nativeEvent); }}
    onPrediction={({ nativeEvent }) => {
      const event = translationFromPrediction(nativeEvent, active && recognitionMode === 'signs', captureId);
      if (event) onTranslation(event, captureId);
    }}
    onDetection={({ nativeEvent }) => {
      if (active && nativeEvent.captureId === captureId && nativeEvent.mode === recognitionMode) onDetection?.(nativeEvent);
    }}
    onStatus={({ nativeEvent }) => {
      const framing = framingFromCamera(nativeEvent, active, captureId);
      if (framing) onFraming(framing, captureId);
    }} />;
}

export const cameraKit: IntegrationKit = {
  mode: 'live', Camera, Avatar: GooseAvatar,
  // Completed local signs arrive from the camera and enter the sentence draft.
  translation: { start: () => () => {} },
  voice: gooseVoice,
};
