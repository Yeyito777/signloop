import type { NativeSyntheticEvent, ViewProps } from 'react-native';
import { requireNativeView } from 'expo';
export type CameraStatus = 'starting' | 'searching' | 'tracking' | 'denied' | 'unavailable' | 'error';
export type CameraStatusEvent = { captureId: number; status: CameraStatus; handCount: number; message: string };
export type LocalSignEvent = { captureId: number; label: string | null; observedAtMS: number };
export type DetectionEvent = LocalSignEvent & {
  mode: 'signs' | 'spelling'; letter: string | null; ready: boolean; detail: string;
  scores: { label: string; distance: number | null }[];
  fps: number; trackingMS: number; matchMS: number; expression: string;
};
export type SignloopCameraProps = ViewProps & {
  active: boolean; captureId: number; recognitionMode?: 'signs' | 'spelling';
  showSkeleton?: boolean; showPose?: boolean; trackFace?: boolean; labMode?: boolean;
  onStatus: (event: NativeSyntheticEvent<CameraStatusEvent>) => void;
  onSign?: (event: NativeSyntheticEvent<LocalSignEvent>) => void;
  onDetection?: (event: NativeSyntheticEvent<DetectionEvent>) => void;
  onClose?: () => void;
};
export const SignloopCamera = requireNativeView<SignloopCameraProps>('SignloopCamera');
