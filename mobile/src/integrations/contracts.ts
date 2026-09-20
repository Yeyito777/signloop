import type { ComponentType } from 'react';
import type { StyleProp, ViewStyle } from 'react-native';
import type { DetectionEvent } from '../../modules/signloop-camera';

/** Emit only diagnoses supported by the scanner. Hand tracking is not ASL recognition. */
export type Framing = 'finding' | 'ready' | 'hands-missing' | 'too-close' | 'too-far' | 'low-light' | 'away'
  | 'camera-denied' | 'camera-unavailable' | 'camera-error' | 'camera-update-required' | 'camera-model-missing'
  | 'body-missing' | 'recognizer-loading' | 'recognizer-missing' | 'recognizer-error';
export type Emotion = 'neutral' | 'happy' | 'thoughtful' | 'sadness' | 'anger' | 'fear';
export type AvatarMode = 'idle' | 'listening' | 'thinking' | 'speaking';
export type AvatarProps = {
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
  recognitionMode?: 'signs' | 'spelling';
  detectionSettings?: { showSkeleton: boolean; showPose: boolean; trackFace: boolean; showScores: boolean };
  onDetection?: (event: DetectionEvent) => void;
  style?: StyleProp<ViewStyle>;
};

export type SignChoice = { label: string; text: string };
export type SignCandidate = SignChoice & {
  attemptId: number;
  observedAtMS: number;
  selected: boolean;
  options: SignChoice[];
  expiresAtMS: number;
  uncertain: boolean;
};

export type TranslationEvent =
  | ({ type: 'candidate' } & SignCandidate)
  | { type: 'sign-preview'; text: string }
  | { type: 'clear-candidate' }
  | { type: 'draft'; text: string }
  | { type: 'thinking' }
  | { type: 'accepted'; id: string; text: string; emotion: Emotion }
  | { type: 'uncertain' }
  | { type: 'offline' };

export interface TranslationAdapter {
  /** Return a cancellation function. Each new captureId starts a fresh generation. */
  start(captureId: number, emit: (event: TranslationEvent) => void): () => void;
}
export interface VoiceAdapter {
  /** Resolve after playback ends, reject on failure, stop immediately on abort. */
  speak(text: string, signal: AbortSignal, onPlaybackStart?: () => void): Promise<void>;
}

export interface IntegrationKit {
  mode: 'demo' | 'camera' | 'live';
  Camera: ComponentType<CameraProps>;
  Avatar: ComponentType<AvatarProps>;
  translation: TranslationAdapter;
  voice: VoiceAdapter;
}
