import type { Emotion, Framing, SignObservation, TranslationEvent } from '../integrations/contracts';
import type { ExpressionEvent } from '../../modules/signloop-camera/events';
import { expressionFromCamera, EXPRESSION_FRESH_MS } from '../integrations/expression.ts';
import { isEmotion } from '../../../goose/src/emotion.ts';
import { isFreshSign, SIGN_FRESH_MS } from '../integrations/localSign.ts';
import { emptySentence, MAX_SENTENCE_CHARACTERS, sentenceEmotion, sentenceText, suspendSentence,
  type SentenceDraft, type SentenceToken } from './sentence.ts';

export type Sheet = 'transcript' | 'correction' | 'sentence-editor' | 'menu' | 'end' | 'demo' | 'detector' | null;
export type Phase = 'framing' | 'listening' | 'signing' | 'thinking' | 'speaking' | 'uncertain' | 'offline' | 'voice-error';
export type Phrase = { id: string; text: string; original?: string; tokens?: readonly SentenceToken[]; emotion: Emotion; status: 'caption' | 'playing' | 'played' | 'interrupted' | 'failed' };
export type Speech = { id: number; phraseId: string; text: string; emotion: Emotion; started: boolean };
export type Session = {
  captureId: number;
  speechId: number;
  framing: Framing;
  phase: Phase;
  paused: boolean;
  sheet: Sheet;
  muted: boolean;
  draft: string;
  sentence: SentenceDraft;
  signPreview: SignObservation | null;
  recognizedAttempt: number | null;
  phrases: Phrase[];
  speech: Speech | null;
  speechQueue: string[];
  expression: ExpressionEvent | null;
  recognitionMode: 'signs' | 'spelling';
  spellingDraft: string;
};

export const initialSession = (): Session => ({
  captureId: 1, speechId: 0, framing: 'finding', phase: 'framing', expression: null, sentence: emptySentence(),
  recognitionMode: 'signs', spellingDraft: '',
  paused: false, sheet: null, muted: false, draft: '', signPreview: null, recognizedAttempt: null, phrases: [], speech: null, speechQueue: [],
});

export type Action =
  | { type: 'expression'; event: ExpressionEvent }
  | { type: 'expire-expression'; observedAtMS: number }
  | { type: 'framing'; framing: Framing; captureId: number }
  | { type: 'translation'; event: TranslationEvent; captureId: number }
  | { type: 'pause' | 'resume' | 'mute' | 'enable-voice' | 'disable-voice' | 'replay' | 'close-sheet' | 'sign-again' | 'retry' }
  | { type: 'open-sheet'; sheet: Exclude<Sheet, null> }
  | { type: 'correct'; text: string }
  | { type: 'commit-sentence' | 'undo-sign' | 'clear-sentence' | 'continue-sentence'; draftId: number; revision: number }
  | { type: 'edit-sentence'; draftId: number; revision: number; text: string }
  | { type: 'speech-ended'; id: number; failed?: boolean }
  | { type: 'speech-started'; id: number }
  | { type: 'recognition-mode'; mode: 'signs' | 'spelling' }
  | { type: 'add-letter'; letter: string }
  | { type: 'delete-letter' | 'clear-spelling' | 'confirm-spelling' }
  | { type: 'expire-preview'; attemptId: number; observedAtMS: number }
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
    ...next, speechId: id, speech: { id, phraseId: phrase.id, text: phrase.text, emotion: phrase.emotion, started: false }, phase: 'speaking',
    phrases: next.phrases.map(p => p.id === phrase.id ? { ...p, status: 'playing' } : p),
  };
}

function enqueuePhrase(state: Session, phrase: Phrase): Session {
  const next = { ...state, phrases: [...state.phrases, phrase] };
  if (state.speech) return { ...next, speechQueue: [...state.speechQueue, phrase.id] };
  return speak(next, phrase);
}

function matchesDraft(state: Session, action: { draftId: number; revision: number }) {
  return action.draftId === state.sentence.id && action.revision === state.sentence.revision;
}

function translate(state: Session, event: TranslationEvent): Session {
  switch (event.type) {
    case 'recognized-sign': {
      if (state.recognitionMode !== 'signs') return state;
      if (!isFreshSign(event) || event.attemptId <= (state.recognizedAttempt ?? 0)) return state;
      const next = translate({ ...state, recognizedAttempt: event.attemptId }, { type: 'accepted',
        id: `sign-${state.captureId}-${event.attemptId}`, text: event.text, emotion: event.emotion });
      return { ...next, signPreview: state.signPreview && state.signPreview.attemptId > event.attemptId
        ? state.signPreview : null };
    }
    case 'sign-preview': {
      if (state.recognitionMode !== 'signs') return state;
      if (!isFreshSign(event) || event.attemptId <= (state.recognizedAttempt ?? 0)
        || (state.signPreview && (event.attemptId < state.signPreview.attemptId
          || (event.attemptId === state.signPreview.attemptId && event.observedAtMS <= state.signPreview.observedAtMS)))) return state;
      const { type: _, ...signPreview } = event;
      return { ...state, signPreview };
    }
    case 'clear-preview': return { ...state, signPreview: null };
    case 'draft': return { ...state, phase: 'signing', draft: event.text };
    case 'thinking': return { ...state, phase: 'thinking' };
    case 'uncertain': return { ...stopSpeech(state), phase: 'uncertain', draft: '', signPreview: null };
    case 'offline': return { ...stopSpeech(state), phase: 'offline', draft: '', sentence: suspendSentence(state.sentence), signPreview: null, recognizedAttempt: null, expression: null, captureId: state.captureId + 1 };
    case 'accepted': {
      if (!event.text.trim() || state.phrases.some(p => p.id === event.id)) return state;
      const phrase: Phrase = { id: event.id, text: event.text.trim(), emotion: isEmotion(event.emotion) ? event.emotion : 'neutral', status: 'caption' };
      return enqueuePhrase({ ...state, draft: '', signPreview: null }, phrase);
    }
  }
}

export function sessionReducer(state: Session, action: Action): Session {
  switch (action.type) {
    case 'commit-sentence': {
      if (!matchesDraft(state, action) || state.paused || state.sheet) return state;
      const text = sentenceText(state.sentence);
      if (!text || text.length > MAX_SENTENCE_CHARACTERS) return state;
      const phrase: Phrase = { id: `sentence-${state.sentence.id}`, text, tokens: state.sentence.tokens,
        emotion: sentenceEmotion(state.sentence.tokens), status: 'caption' };
      return enqueuePhrase({ ...state, sentence: emptySentence(state.sentence.id + 1) }, phrase);
    }
    case 'undo-sign':
      if (!matchesDraft(state, action) || state.sheet || state.sentence.editedText !== null || !state.sentence.tokens.length) return state;
      return { ...state, sentence: { ...state.sentence, revision: state.sentence.revision + 1,
        tokens: state.sentence.tokens.slice(0, -1), needsContinuation: state.sentence.tokens.length > 1 && state.sentence.needsContinuation } };
    case 'clear-sentence':
      return matchesDraft(state, action) && !state.sheet
        ? { ...state, sentence: emptySentence(state.sentence.id + 1) } : state;
    case 'continue-sentence':
      if (!matchesDraft(state, action) || state.paused || state.sheet || state.sentence.editedText !== null) return state;
      return { ...state, sentence: { ...state.sentence, revision: state.sentence.revision + 1, needsContinuation: false },
        captureId: state.captureId + 1, framing: 'finding', phase: state.speech ? 'speaking' : 'framing',
        signPreview: null, recognizedAttempt: null, expression: null };
    case 'edit-sentence':
      if (!matchesDraft(state, action) || state.sheet !== 'sentence-editor'
        || !action.text.trim() || action.text.trim().length > MAX_SENTENCE_CHARACTERS) return state;
      return { ...state, sheet: null, sentence: { ...state.sentence, revision: state.sentence.revision + 1,
        editedText: action.text.trim(), needsContinuation: false },
        captureId: state.captureId + 1, framing: 'finding', signPreview: null, recognizedAttempt: null, expression: null };
    case 'expression': {
      if (!canCapture(state)) return state;
      const event = expressionFromCamera(action.event, state.captureId);
      if (!event || (state.expression && event.observedAtMS <= state.expression.observedAtMS)) return state;
      return { ...state, expression: event };
    }
    case 'expire-expression':
      return state.expression?.observedAtMS === action.observedAtMS
        && Date.now() - action.observedAtMS >= EXPRESSION_FRESH_MS
        ? { ...state, expression: { ...state.expression, status: 'stale', emotion: 'neutral' } } : state;
    case 'recognition-mode':
      if (!canCapture(state)) return state;
      return { ...stopSpeech(state), sentence: suspendSentence(state.sentence), recognitionMode: action.mode, expression: null, captureId: state.captureId + 1,
        signPreview: null, recognizedAttempt: null, draft: '', framing: 'finding', phase: 'framing' };
    case 'add-letter':
      return state.recognitionMode === 'spelling' && canCapture(state) && /^[AURELIO]$/.test(action.letter) && state.spellingDraft.length < 40
        ? { ...state, spellingDraft: state.spellingDraft + action.letter } : state;
    case 'delete-letter': return { ...state, spellingDraft: state.spellingDraft.slice(0, -1) };
    case 'clear-spelling': return { ...state, spellingDraft: '' };
    case 'confirm-spelling':
      if (!canCapture(state) || state.recognitionMode !== 'spelling' || !/^[AURELIO]{1,40}$/.test(state.spellingDraft)) return state;
      return translate({ ...state, spellingDraft: '' }, { type: 'accepted',
        id: `spelled-${state.captureId}-${state.phrases.length}`, text: state.spellingDraft, emotion: 'neutral' });
    case 'expire-preview':
      return state.signPreview?.attemptId === action.attemptId
        && state.signPreview.observedAtMS === action.observedAtMS
        && Date.now() - action.observedAtMS >= SIGN_FRESH_MS
        ? { ...state, signPreview: null } : state;
    case 'speech-started':
      return state.speech?.id === action.id
        ? { ...state, speech: { ...state.speech, started: true } } : state;
    case 'framing':
      if (!canCapture(state) || action.captureId !== state.captureId) return state;
      if (action.framing === state.framing) return state;
      // A lost frame invalidates in-flight recognition. Existing accepted speech can finish.
      return { ...state, framing: action.framing,
        sentence: action.framing === 'ready' ? state.sentence : suspendSentence(state.sentence),
        expression: action.framing === 'ready' ? state.expression : null,
        signPreview: action.framing === 'ready' ? state.signPreview : null,
        recognizedAttempt: action.framing === 'ready' ? state.recognizedAttempt : null,
        captureId: state.captureId + (state.framing === 'ready' && action.framing !== 'ready' ? 1 : 0),
        draft: action.framing === 'ready' ? state.draft : '',
        phase: state.phase === 'speaking' ? state.phase : action.framing === 'ready' ? 'listening' : 'framing' };
    case 'translation':
      if (!canCapture(state) || state.framing !== 'ready' || action.captureId !== state.captureId) return state;
      return translate(state, action.event);
    case 'pause':
      return { ...stopSpeech(state), paused: true, draft: '', sentence: suspendSentence(state.sentence), signPreview: null, recognizedAttempt: null, expression: null, captureId: state.captureId + 1,
        phase: state.phase === 'offline' ? 'offline' : 'listening' };
    case 'resume':
      return { ...state, paused: false, framing: 'finding', phase: 'framing', draft: '', signPreview: null, recognizedAttempt: null, expression: null, captureId: state.captureId + 1 };
    case 'open-sheet':
      return { ...stopSpeech(state), sheet: action.sheet, draft: '', sentence: suspendSentence(state.sentence), signPreview: null, recognizedAttempt: null, expression: null, captureId: state.captureId + 1,
        phase: state.phase === 'offline' ? 'offline' : 'listening' };
    case 'close-sheet':
      return { ...state, sheet: null, signPreview: null, recognizedAttempt: null, framing: 'finding', phase: state.phase === 'offline' ? 'offline' : 'framing', expression: null, captureId: state.captureId + 1 };
    case 'mute':
      return { ...stopSpeech(state), muted: !state.muted, phase: state.phase === 'speaking' ? 'listening' : state.phase };
    case 'enable-voice':
      return { ...state, muted: false };
    case 'disable-voice':
      return { ...stopSpeech(state), muted: true, phase: state.phase === 'speaking' ? 'listening' : state.phase };
    case 'replay': {
      const phrase = state.phrases.at(-1);
      if (!phrase || state.paused || state.sheet) return state;
      // Don't cancel the automatic first playback if someone taps replay while it is already starting.
      if (state.speech?.phraseId === phrase.id) return state;
      return speak(state, phrase);
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
      if (!previous || !action.text.trim() || action.text.trim().length > MAX_SENTENCE_CHARACTERS) return state;
      const phrase: Phrase = { ...previous, text: action.text.trim(), original: previous.original ?? previous.text, status: 'caption' };
      const next = { ...state, sheet: null, paused: false, framing: 'finding' as Framing, signPreview: null, recognizedAttempt: null,
        expression: null, captureId: state.captureId + 1,
        phrases: state.phrases.map(p => p.id === phrase.id ? phrase : p) };
      return speak(next, phrase);
    }
    case 'sign-again':
      return { ...stopSpeech(state), sentence: emptySentence(state.sentence.id + 1), sheet: null, paused: false,
        framing: 'finding', phase: 'framing', draft: '', signPreview: null, recognizedAttempt: null, expression: null, captureId: state.captureId + 1 };
    case 'retry':
      return { ...stopSpeech(state), sentence: suspendSentence(state.sentence), sheet: null, paused: false, framing: 'finding', phase: 'framing', draft: '', signPreview: null, recognizedAttempt: null, expression: null, captureId: state.captureId + 1 };
    case 'demo-framing':
      return { ...stopSpeech(state), sheet: null, paused: false, framing: action.framing,
        phase: action.framing === 'ready' ? 'listening' : 'framing', expression: null, captureId: state.captureId + 1, draft: '', signPreview: null, recognizedAttempt: null };
    case 'demo-event':
      return translate({ ...state, sheet: null, paused: false, framing: 'ready', signPreview: null, recognizedAttempt: null,
        expression: null, captureId: state.captureId + 1 }, action.event);
  }
}
