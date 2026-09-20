import type { Emotion, Framing, SignCandidate, TranslationEvent } from '../integrations/contracts';

export type Sheet = 'transcript' | 'correction' | 'menu' | 'end' | 'demo' | 'detector' | null;
export type Phase = 'framing' | 'listening' | 'signing' | 'thinking' | 'speaking' | 'uncertain' | 'offline' | 'voice-error';
export type Phrase = { id: string; text: string; original?: string; emotion: Emotion; status: 'caption' | 'playing' | 'played' | 'interrupted' | 'failed' };
export type Speech = { id: number; phraseId: string; text: string; started: boolean };
export type Session = {
  captureId: number;
  speechId: number;
  framing: Framing;
  phase: Phase;
  paused: boolean;
  sheet: Sheet;
  muted: boolean;
  draft: string;
  candidate: SignCandidate | null;
  signPreview: string | null;
  reviewedAttempt: number | null;
  phrases: Phrase[];
  speech: Speech | null;
  speechQueue: string[];
  recognitionMode: 'signs' | 'spelling';
  spellingDraft: string;
};

export const initialSession = (): Session => ({
  captureId: 1, speechId: 0, framing: 'finding', phase: 'framing',
  recognitionMode: 'signs', spellingDraft: '',
  paused: false, sheet: null, muted: false, draft: '', candidate: null, signPreview: null, reviewedAttempt: null, phrases: [], speech: null, speechQueue: [],
});

export type Action =
  | { type: 'framing'; framing: Framing; captureId: number }
  | { type: 'translation'; event: TranslationEvent; captureId: number }
  | { type: 'pause' | 'resume' | 'mute' | 'disable-voice' | 'replay' | 'close-sheet' | 'sign-again' | 'retry' }
  | { type: 'open-sheet'; sheet: Exclude<Sheet, null> }
  | { type: 'correct'; text: string }
  | { type: 'speech-ended'; id: number; failed?: boolean }
  | { type: 'speech-started'; id: number }
  | { type: 'recognition-mode'; mode: 'signs' | 'spelling' }
  | { type: 'add-letter'; letter: string }
  | { type: 'delete-letter' | 'clear-spelling' | 'confirm-spelling' }
  | { type: 'confirm-candidate' | 'reject-candidate' | 'expire-candidate'; attemptId: number }
  | { type: 'select-candidate'; attemptId: number; label: string }
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
    ...next, speechId: id, speech: { id, phraseId: phrase.id, text: phrase.text, started: false }, phase: 'speaking',
    phrases: next.phrases.map(p => p.id === phrase.id ? { ...p, status: 'playing' } : p),
  };
}

function translate(state: Session, event: TranslationEvent): Session {
  switch (event.type) {
    case 'candidate': {
      if (state.recognitionMode !== 'signs') return state;
      if (!Number.isSafeInteger(event.attemptId) || event.attemptId <= 0
        || event.attemptId <= (state.reviewedAttempt ?? 0)
        || (state.candidate && (event.attemptId < state.candidate.attemptId
          || (event.attemptId === state.candidate.attemptId && event.observedAtMS <= state.candidate.observedAtMS)))
        || !Number.isFinite(event.observedAtMS)
        || !event.text.trim() || event.text.length > 500 || !Number.isFinite(event.expiresAtMS)
        || event.expiresAtMS <= Date.now() || event.options.length < 1 || event.options.length > 3
        || !event.options.some(option => option.label === event.label && option.text === event.text)) return state;
      // A tap freezes the intended sign, including across later segment results.
      // Expiration and tracking/lifecycle invalidations still clear it normally.
      // Leave expiry to its action even if a fresh event wins the timer race.
      if (state.candidate?.selected) return state;
      const { type: _, ...candidate } = event;
      return { ...state, candidate, signPreview: null };
    }
    case 'sign-preview':
      return state.candidate ? state : { ...state, signPreview: event.text || null };
    case 'clear-candidate': return { ...state, candidate: null, signPreview: null };
    case 'draft': return { ...state, phase: 'signing', draft: event.text };
    case 'thinking': return { ...state, phase: 'thinking' };
    case 'uncertain': return { ...stopSpeech(state), phase: 'uncertain', draft: '', candidate: null, signPreview: null };
    case 'offline': return { ...stopSpeech(state), phase: 'offline', draft: '', candidate: null, signPreview: null, captureId: state.captureId + 1 };
    case 'accepted': {
      if (!event.text.trim() || state.phrases.some(p => p.id === event.id)) return state;
      const phrase: Phrase = { id: event.id, text: event.text.trim(), emotion: event.emotion, status: 'caption' };
      const next = { ...state, draft: '', candidate: null, signPreview: null,
        reviewedAttempt: state.candidate?.attemptId ?? state.reviewedAttempt, phrases: [...state.phrases, phrase] };
      if (state.speech) return { ...next, speechQueue: [...state.speechQueue, phrase.id] };
      return speak(next, phrase);
    }
  }
}

export function sessionReducer(state: Session, action: Action): Session {
  switch (action.type) {
    case 'recognition-mode':
      if (!canCapture(state)) return state;
      return { ...stopSpeech(state), recognitionMode: action.mode, captureId: state.captureId + 1,
        candidate: null, signPreview: null, reviewedAttempt: null, draft: '', framing: 'finding', phase: 'framing' };
    case 'add-letter':
      return state.recognitionMode === 'spelling' && canCapture(state) && /^[AURELIO]$/.test(action.letter) && state.spellingDraft.length < 40
        ? { ...state, spellingDraft: state.spellingDraft + action.letter } : state;
    case 'delete-letter': return { ...state, spellingDraft: state.spellingDraft.slice(0, -1) };
    case 'clear-spelling': return { ...state, spellingDraft: '' };
    case 'confirm-spelling':
      if (!canCapture(state) || state.recognitionMode !== 'spelling' || !/^[AURELIO]{1,40}$/.test(state.spellingDraft)) return state;
      return translate({ ...state, spellingDraft: '' }, { type: 'accepted',
        id: `spelled-${state.captureId}-${state.phrases.length}`, text: state.spellingDraft, emotion: 'neutral' });
    case 'select-candidate': {
      if (!state.candidate || state.candidate.attemptId !== action.attemptId
        || !canCapture(state) || state.framing !== 'ready' || state.candidate.expiresAtMS <= Date.now()) return state;
      const option = state.candidate.options.find(choice => choice.label === action.label);
      return option ? { ...state, candidate: { ...state.candidate, ...option, selected: true, uncertain: true } } : state;
    }
    case 'reject-candidate':
    case 'expire-candidate':
      if (!state.candidate || state.candidate.attemptId !== action.attemptId
        || (action.type === 'expire-candidate' && state.candidate.expiresAtMS > Date.now())) return state;
      return { ...state, candidate: null, signPreview: null, reviewedAttempt: action.attemptId };
    case 'confirm-candidate':
      if (!state.candidate || !state.candidate.selected || state.candidate.attemptId !== action.attemptId
        || !canCapture(state) || state.framing !== 'ready') return state;
      if (state.candidate.expiresAtMS <= Date.now()) {
        return { ...state, candidate: null, signPreview: null, reviewedAttempt: action.attemptId };
      }
      return translate({ ...state, candidate: null, signPreview: null, reviewedAttempt: action.attemptId }, { type: 'accepted',
        id: `confirmed-${state.captureId}-${action.attemptId}`,
        text: state.candidate.text, emotion: 'neutral' });
    case 'speech-started':
      return state.speech?.id === action.id
        ? { ...state, speech: { ...state.speech, started: true } } : state;
    case 'framing':
      if (!canCapture(state) || action.captureId !== state.captureId) return state;
      if (action.framing === state.framing) return state;
      // A lost frame invalidates in-flight recognition. Existing accepted speech can finish.
      return { ...state, framing: action.framing,
        candidate: action.framing === 'ready' ? state.candidate : null,
        signPreview: action.framing === 'ready' ? state.signPreview : null,
        reviewedAttempt: action.framing === 'ready' ? state.reviewedAttempt : null,
        captureId: state.captureId + (state.framing === 'ready' && action.framing !== 'ready' ? 1 : 0),
        draft: action.framing === 'ready' ? state.draft : '',
        phase: state.phase === 'speaking' ? state.phase : action.framing === 'ready' ? 'listening' : 'framing' };
    case 'translation':
      if (!canCapture(state) || state.framing !== 'ready' || action.captureId !== state.captureId) return state;
      return translate(state, action.event);
    case 'pause':
      return { ...stopSpeech(state), paused: true, draft: '', candidate: null, signPreview: null, reviewedAttempt: null, captureId: state.captureId + 1,
        phase: state.phase === 'offline' ? 'offline' : 'listening' };
    case 'resume':
      return { ...state, paused: false, framing: 'finding', phase: 'framing', draft: '', candidate: null, signPreview: null, reviewedAttempt: null, captureId: state.captureId + 1 };
    case 'open-sheet':
      return { ...stopSpeech(state), sheet: action.sheet, draft: '', candidate: null, signPreview: null, reviewedAttempt: null, captureId: state.captureId + 1,
        phase: state.phase === 'offline' ? 'offline' : 'listening' };
    case 'close-sheet':
      return { ...state, sheet: null, candidate: null, signPreview: null, reviewedAttempt: null, framing: 'finding', phase: state.phase === 'offline' ? 'offline' : 'framing', captureId: state.captureId + 1 };
    case 'mute':
      return { ...stopSpeech(state), muted: !state.muted, phase: state.phase === 'speaking' ? 'listening' : state.phase };
    case 'disable-voice':
      return { ...stopSpeech(state), muted: true, phase: state.phase === 'speaking' ? 'listening' : state.phase };
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
      return { ...stopSpeech(state), sheet: null, paused: false, framing: 'finding', phase: 'framing', draft: '', candidate: null, signPreview: null, reviewedAttempt: null, captureId: state.captureId + 1 };
    case 'demo-framing':
      return { ...stopSpeech(state), sheet: null, paused: false, framing: action.framing,
        phase: action.framing === 'ready' ? 'listening' : 'framing', captureId: state.captureId + 1, draft: '', candidate: null, signPreview: null, reviewedAttempt: null };
    case 'demo-event':
      return translate({ ...state, sheet: null, paused: false, framing: 'ready', captureId: state.captureId + 1 }, action.event);
  }
}
