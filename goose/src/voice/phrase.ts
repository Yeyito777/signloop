import type { GooseEmotion } from '../components/goose/motion.ts';
import { prepareSpeechText } from './elevenlabs.ts';

/** What teammates send. Drafts can trickle in; ElevenLabs only runs when ready is true. */
export type GoosePhrase = {
  text: string;
  emotion: GooseEmotion;
  ready: boolean;
};

/** Null while the phrase is still coming in. English once someone says the line is done. */
export function englishWhenReady(phrase: GoosePhrase): string | null {
  if (!phrase.ready) return null;
  return prepareSpeechText(phrase.text);
}
