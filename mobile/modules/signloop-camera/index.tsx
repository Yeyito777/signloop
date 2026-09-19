import { forwardRef, type RefAttributes } from 'react';
import type { NativeSyntheticEvent, ViewProps } from 'react-native';
import { requireNativeView } from 'expo';

export type CameraStatus = 'starting' | 'searching' | 'tracking' | 'denied' | 'unavailable' | 'error';
export type CameraStatusEvent = { captureId: number; status: CameraStatus; handCount: number; message: string };
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
};

const NativeView = requireNativeView<SignloopCameraProps & RefAttributes<SignloopCameraHandle>>('SignloopCamera');
export const SignloopCamera = forwardRef<SignloopCameraHandle, SignloopCameraProps>((props, ref) =>
  <NativeView {...props} ref={ref} />,
);
