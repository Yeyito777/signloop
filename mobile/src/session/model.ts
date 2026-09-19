import type { Emotion, Framing, TranslationEvent } from '../integrations/contracts';

export type Sheet = 'transcript' | 'correction' | 'menu' | 'end' | 'demo' | null;
export type Phase = 'framing' | 'listening' | 'signing' | 'thinking' | 'speaking' | 'uncertain' | 'offline' | 'voice-error';
export type Phrase = { id: string; text: string; original?: string; emotion: Emotion; status: 'caption' | 'playing' | 'played' | 'interrupted' | 'failed' };
export type Speech = { id: number; phraseId: string; text: string };
export type Session = {
  captureId: number;
  speechId: number;
  framing: Framing;
  phase: Phase;
  paused: boolean;
  sheet: Sheet;
  muted: boolean;
  draft: string;
  phrases: Phrase[];
  speech: Speech | null;
  speechQueue: string[];
};

export const initialSession = (): Session => ({
  captureId: 1, speechId: 0, framing: 'finding', phase: 'framing',
  paused: false, sheet: null, muted: false, draft: '', phrases: [], speech: null, speechQueue: [],
});

export type Action =
  | { type: 'framing'; framing: Framing; captureId: number }
  | { type: 'translation'; event: TranslationEvent; captureId: number }
  | { type: 'pause' | 'resume' | 'mute' | 'replay' | 'close-sheet' | 'sign-again' | 'retry' }
  | { type: 'open-sheet'; sheet: Exclude<Sheet, null> }
  | { type: 'correct'; text: string }
  | { type: 'speech-ended'; id: number; failed?: boolean }
  | { type: 'demo-framing'; framing: Framing }
  | { type: 'demo-event'; event: TranslationEvent };

export function canCapture(state: Session) {
  return !state.paused && !state.sheet && state.phase !== 'offline';
}

function stopSpeech(state: Session): Session {
  return { ...state, speech: null, speechQueue: [], phrases: state.phrases.map(p => p.status === 'playing' ? { ...p, status: 'interrupted' } : p) };
}

function speak(state: Session, phrase: Phrase): Session {
  const next = stopSpeech(state);
  if (state.muted) return { ...next, phase: 'listening' };
  const id = state.speechId + 1;
  return {
    ...next, speechId: id, speech: { id, phraseId: phrase.id, text: phrase.text }, phase: 'speaking',
    phrases: next.phrases.map(p => p.id === phrase.id ? { ...p, status: 'playing' } : p),
  };
}

function translate(state: Session, event: TranslationEvent): Session {
  switch (event.type) {
    case 'draft': return { ...state, phase: 'signing', draft: event.text };
    case 'thinking': return { ...state, phase: 'thinking' };
    case 'uncertain': return { ...stopSpeech(state), phase: 'uncertain', draft: '' };
    case 'offline': return { ...stopSpeech(state), phase: 'offline', draft: '', captureId: state.captureId + 1 };
    case 'accepted': {
      if (!event.text.trim() || state.phrases.some(p => p.id === event.id)) return state;
      const phrase: Phrase = { id: event.id, text: event.text.trim(), emotion: event.emotion, status: 'caption' };
      const next = { ...state, draft: '', phrases: [...state.phrases, phrase] };
      if (state.speech) return { ...next, speechQueue: [...state.speechQueue, phrase.id] };
      return speak(next, phrase);
    }
  }
}

export function sessionReducer(state: Session, action: Action): Session {
  switch (action.type) {
    case 'framing':
      if (!canCapture(state) || action.captureId !== state.captureId) return state;
      if (action.framing === state.framing) return state;
      // A lost frame invalidates in-flight recognition. Existing accepted speech can finish.
      return { ...state, framing: action.framing,
        captureId: state.captureId + (state.framing === 'ready' && action.framing !== 'ready' ? 1 : 0),
        draft: action.framing === 'ready' ? state.draft : '',
        phase: state.phase === 'speaking' ? state.phase : action.framing === 'ready' ? 'listening' : 'framing' };
    case 'translation':
      if (!canCapture(state) || state.framing !== 'ready' || action.captureId !== state.captureId) return state;
      return translate(state, action.event);
    case 'pause':
      return { ...stopSpeech(state), paused: true, draft: '', captureId: state.captureId + 1,
        phase: state.phase === 'offline' ? 'offline' : 'listening' };
    case 'resume':
      return { ...state, paused: false, framing: 'finding', phase: 'framing', draft: '', captureId: state.captureId + 1 };
    case 'open-sheet':
      return { ...stopSpeech(state), sheet: action.sheet, draft: '', captureId: state.captureId + 1,
        phase: state.phase === 'offline' ? 'offline' : 'listening' };
    case 'close-sheet':
      return { ...state, sheet: null, framing: 'finding', phase: state.phase === 'offline' ? 'offline' : 'framing', captureId: state.captureId + 1 };
    case 'mute':
      return { ...stopSpeech(state), muted: !state.muted, phase: state.phase === 'speaking' ? 'listening' : state.phase };
    case 'replay': {
      const phrase = state.phrases.at(-1);
      return phrase && !state.paused && !state.sheet ? speak(state, phrase) : state;
    }
    case 'speech-ended': {
      if (state.speech?.id !== action.id) return state;
      const next: Session = { ...state, speech: null, phase: action.failed ? 'voice-error' : 'listening',
        phrases: state.phrases.map(p => p.id === state.speech!.phraseId ? { ...p, status: action.failed ? 'failed' : 'played' } : p) };
      if (action.failed) return { ...next, speechQueue: [] };
      const queued = next.phrases.find(p => p.id === state.speechQueue[0]);
      return queued ? { ...speak(next, queued), speechQueue: state.speechQueue.slice(1) } : next;
    }
    case 'correct': {
      const previous = state.phrases.at(-1);
      if (!previous || !action.text.trim()) return state;
      const phrase: Phrase = { ...previous, text: action.text.trim(), original: previous.original ?? previous.text, status: 'caption' };
      const next = { ...state, sheet: null, paused: false, framing: 'finding' as Framing, captureId: state.captureId + 1,
        phrases: state.phrases.map(p => p.id === phrase.id ? phrase : p) };
      return speak(next, phrase);
    }
    case 'sign-again':
    case 'retry':
      return { ...stopSpeech(state), sheet: null, paused: false, framing: 'finding', phase: 'framing', draft: '', captureId: state.captureId + 1 };
    case 'demo-framing':
      return { ...stopSpeech(state), sheet: null, paused: false, framing: action.framing,
        phase: action.framing === 'ready' ? 'listening' : 'framing', captureId: state.captureId + 1, draft: '' };
    case 'demo-event':
      return translate({ ...state, sheet: null, paused: false, framing: 'ready', captureId: state.captureId + 1 }, action.event);
  }
}
