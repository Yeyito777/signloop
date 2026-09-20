import type { ComponentType } from 'react';
import type { StyleProp, ViewStyle } from 'react-native';
import type { EmoteProps } from '../../../goose/src/components/goose/emotes';
import type { Emotion } from '../../../goose/src/emotion';
export type { Emotion } from '../../../goose/src/emotion';
import type { ExpressionEvent } from '../../modules/signloop-camera/events';
import type { DetectionEvent } from '../../modules/signloop-camera';

/** Emit only diagnoses supported by the scanner. Hand tracking is not ASL recognition. */
export type Framing = 'finding' | 'ready' | 'hands-missing' | 'too-close' | 'too-far' | 'low-light' | 'away'
  | 'camera-denied' | 'camera-unavailable' | 'camera-error' | 'camera-update-required' | 'camera-model-missing'
  | 'body-missing' | 'recognizer-loading' | 'recognizer-missing' | 'recognizer-error';
export type AvatarMode = 'idle' | 'listening' | 'thinking' | 'speaking';
export type AvatarProps = EmoteProps & {
  mode: AvatarMode;
  emotion: Emotion;
  reducedMotion: boolean;
  style?: StyleProp<ViewStyle>;
};

/** The native view owns capture AND processing. Never open a second camera for the preview. */
export type CameraProps = {
  active: boolean;
  captureId: number;
  framing: Framing;
  onFraming: (framing: Framing, captureId: number) => void;
  onTranslation: (event: TranslationEvent, captureId: number) => void;
  onExpression: (event: ExpressionEvent) => void;
  recognitionMode?: 'signs' | 'spelling';
  detectionSettings?: { showSkeleton: boolean; showPose: boolean; trackFace: boolean; showScores: boolean };
  onDetection?: (event: DetectionEvent) => void;
  style?: StyleProp<ViewStyle>;
};

export type SignObservation = {
  text: string;
  attemptId: number;
  observedAtMS: number;
};

export type TranslationEvent =
  | ({ type: 'recognized-sign'; emotion: Emotion } & SignObservation)
  | ({ type: 'sign-preview' } & SignObservation)
  | { type: 'clear-preview' }
  | { type: 'draft'; text: string }
  | { type: 'thinking' }
  | { type: 'accepted'; id: string; text: string; emotion: Emotion }
  | { type: 'uncertain' }
  | { type: 'offline' };

export interface TranslationAdapter {
  /** Return a cancellation function. Each new captureId starts a fresh generation. */
  start(captureId: number, emit: (event: TranslationEvent) => void): () => void;
}
export type SpeechRequest = Readonly<{ text: string; emotion: Emotion }>;
export interface VoiceAdapter {
  /** Resolve after playback ends, reject on failure, stop immediately on abort. */
  speak(request: SpeechRequest, signal: AbortSignal, onPlaybackStart?: () => void): Promise<void>;
}

export interface IntegrationKit {
  mode: 'demo' | 'camera' | 'live';
  Camera: ComponentType<CameraProps>;
  Avatar: ComponentType<AvatarProps>;
  translation: TranslationAdapter;
  voice: VoiceAdapter;
}
