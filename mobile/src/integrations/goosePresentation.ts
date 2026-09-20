import type { AvatarMode, Emotion } from './contracts';
import type { GooseActivity, GooseEmotion } from '../../../goose/src/components/goose/motion';

const activities: Record<AvatarMode, GooseActivity> = {
  idle: 'idle', listening: 'watching', thinking: 'thinking', speaking: 'speaking',
};
const emotions: Record<Emotion, GooseEmotion | undefined> = {
  neutral: undefined, joy: 'joy',
  sadness: 'sadness', anger: 'anger', fear: 'fear', disgust: 'disgust',
};

/** Activity describes the app; expression is live or owned by the playing phrase. */
export function goosePresentation(mode: AvatarMode, emotion: Emotion) {
  return { activity: activities[mode], emotion: emotions[emotion] };
}
