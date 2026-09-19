import { forwardRef, type RefAttributes } from 'react';
import type { NativeSyntheticEvent, ViewProps } from 'react-native';
import { requireNativeView } from 'expo';

export type CameraStatus = 'starting' | 'searching' | 'tracking' | 'denied' | 'unavailable' | 'error';
export type CameraStatusEvent = { captureId: number; status: CameraStatus; handCount: number; message: string };
export type LocalSignEvent = { captureId: number; label: string | null; observedAtMS: number };
/** Decision from the on-device SignEngine. Only present when a cleared model is bundled. `label` is a
 * supported sign, 'UNKNOWN', or null for a state-only update. Nothing here is a caption until the user confirms. */
export type SignPredictionEvent = {
  captureId: number;
  label: string | null;
  confidence: number;
  state: 'idle' | 'possible_sign' | 'sign_in_progress' | 'sign_complete' | 'prediction';
  trackingQuality: number;
  tier: 'show' | 'retry' | 'unknown' | 'low_tracking' | 'unusable' | null;
  reason: string | null;
  observedAtMS: number;
};
export type LandmarkFrame = {
  timestampMS: number;
  hands: { handedness: string; handednessScore: number; joints: { x: number; y: number; z: number }[] }[];
};
export type SignloopCameraHandle = {
  getRecentFrames(): Promise<{ captureId: number; frames: LandmarkFrame[] }>;
};
export type SignloopCameraProps = ViewProps & {
  active: boolean;
  captureId: number;
  showSkeleton?: boolean;
  onStatus: (event: NativeSyntheticEvent<CameraStatusEvent>) => void;
  onSign?: (event: NativeSyntheticEvent<LocalSignEvent>) => void;
  onPrediction?: (event: NativeSyntheticEvent<SignPredictionEvent>) => void;
};

const NativeView = requireNativeView<SignloopCameraProps & RefAttributes<SignloopCameraHandle>>('SignloopCamera');
export const SignloopCamera = forwardRef<SignloopCameraHandle, SignloopCameraProps>((props, ref) =>
  <NativeView {...props} ref={ref} />,
);
