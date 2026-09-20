import type { Emotion, SignObservation } from '../integrations/contracts.ts';
import type { SignLabel } from '../integrations/localSign.ts';

export const MAX_SENTENCE_CHARACTERS = 500;
export type SentenceToken = Readonly<SignObservation & { label: SignLabel; captureId: number; emotion: Emotion }>;
export type SentenceDraft = Readonly<{
  id: number;
  revision: number;
  tokens: readonly SentenceToken[];
  editedText: string | null;
  needsContinuation: boolean;
}>;

const words: Record<SignLabel, string> = {
  HELLO: 'hello', MY: 'my', NAME: 'name', TODAY: 'today', WE: 'we', SHOW: 'show',
  PHONE: 'phone', PLEASE: 'please', SORRY: 'sorry', THANKYOU: 'thank you', ILOVEYOU: 'I love you',
};

// Only this exact presentation sequence supplies an article. Other sequences
// retain their words and order; names and missing facts must come from the user.
const templates: Readonly<Record<string, string>> = {
  'TODAY WE SHOW PHONE': 'Today we show the phone.',
};

export const emptySentence = (id = 1): SentenceDraft => ({
  id, revision: 0, tokens: [], editedText: null, needsContinuation: false,
});

export function sentenceText(draft: SentenceDraft): string {
  if (draft.editedText !== null) return draft.editedText.trim();
  if (!draft.tokens.length) return '';
  const key = draft.tokens.map(token => token.label).join(' ');
  if (Object.hasOwn(templates, key)) return templates[key];
  const text = draft.tokens.map(token => words[token.label]).join(' ');
  return text.charAt(0).toUpperCase() + text.slice(1) + '.';
}

export function sentenceEmotion(tokens: readonly SentenceToken[]): Emotion {
  const counts = new Map<Emotion, number>();
  for (const token of tokens) counts.set(token.emotion, (counts.get(token.emotion) ?? 0) + 1);
  const ranked = [...counts].sort((a, b) => b[1] - a[1]);
  return ranked.length && ranked[0][1] !== ranked[1]?.[1] ? ranked[0][0] : 'neutral';
}

export function suspendSentence(draft: SentenceDraft): SentenceDraft {
  return sentenceText(draft) && !draft.needsContinuation
    ? { ...draft, revision: draft.revision + 1, needsContinuation: true } : draft;
}

export function canAppendSentence(draft: SentenceDraft): boolean {
  return !draft.needsContinuation && draft.editedText === null;
}
