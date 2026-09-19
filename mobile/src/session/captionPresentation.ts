import type { IntegrationKit } from '../integrations/contracts';
import type { Session } from './model';

/** Accepted words stay readable through tracking loss, the next draft, errors and pauses. */
export function captionPresentation(state: Session, mode: IntegrationKit['mode']) {
  const phrase = state.phrases.at(-1);
  const composing = state.phase === 'signing' || state.phase === 'thinking';
  const draft = !phrase && composing ? state.draft : '';
  const text = phrase?.text ?? (draft || 'Your words will appear here.');
  const label = phrase ? mode === 'demo' ? 'Sample caption' : 'English' : draft ? 'Draft · not spoken' : 'English';
  let delivery = '';
  if (phrase) {
    if (state.paused) delivery = 'Paused';
    else if (state.muted) delivery = 'Voice off';
    else if (state.speech?.phraseId === phrase.id) delivery = mode === 'demo' ? 'Playing · silent preview'
      : state.speech.started ? 'Speaking' : 'Preparing voice…';
    else if (state.speechQueue.includes(phrase.id)) delivery = 'Waiting to speak';
    else if (phrase.status === 'played') delivery = mode === 'demo' ? 'Preview finished' : 'Spoken';
    else if (phrase.status === 'failed') delivery = 'Voice unavailable';
    else if (phrase.status === 'interrupted') delivery = 'Playback stopped';
    else delivery = 'Caption ready';
  }
  let activity = '';
  if (state.phase === 'signing') activity = phrase ? 'Reading your next phrase…' : 'Reading your signs…';
  if (state.phase === 'thinking') activity = phrase ? 'Translating your next phrase…' : 'Translating…';
  if (state.paused) activity = '';
  const notice = state.phase === 'uncertain' ? 'That phrase wasn’t clear. Nothing new was spoken.'
    : state.phase === 'offline' ? 'Connection lost. Your completed phrases are still here.'
    : state.phase === 'voice-error' ? 'Voice couldn’t play. Your caption is still here.' : '';
  return { phrase, text, label, delivery, activity, notice, draft: !!draft };
}
