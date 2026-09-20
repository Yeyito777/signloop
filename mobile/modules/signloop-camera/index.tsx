import type { NativeSyntheticEvent, ViewProps } from 'react-native';
import { requireNativeView } from 'expo';
import type { CameraStatusEvent, SignPredictionEvent, ExpressionEvent } from './events';
export type { CameraStatus, CameraStatusEvent, SignPredictionEvent } from './events';

export type SignloopCameraProps = ViewProps & {
  active: boolean;
  captureId: number;
  showSkeleton?: boolean;
  onStatus: (event: NativeSyntheticEvent<CameraStatusEvent>) => void;
  onPrediction: (event: NativeSyntheticEvent<SignPredictionEvent>) => void;
  onExpression: (event: NativeSyntheticEvent<ExpressionEvent>) => void;
};

// Images and landmark buffers remain native; only status and predictions cross the bridge.
export const SignloopCamera = requireNativeView<SignloopCameraProps>('SignloopCamera');
