import { useCallback, useEffect, useReducer, useState } from 'react';
import { AppState } from 'react-native';
import type { Framing, IntegrationKit, TranslationEvent } from '../integrations/contracts';
import { canCapture, initialSession, sessionReducer, type Action } from './model';
import { getVoiceSettings, subscribeVoiceSettings } from '../integrations/voiceSettings';
import type { ExpressionEvent } from '../../modules/signloop-camera/events';
import { EXPRESSION_FRESH_MS } from '../integrations/expression';

export function useConversation(kit: IntegrationKit) {
  const [state, send] = useReducer(sessionReducer, undefined, () => ({
    ...initialSession(), muted: kit.mode !== 'demo' && !getVoiceSettings().enabled,
  }));
  useEffect(() => subscribeVoiceSettings(() => {
    if (kit.mode !== 'demo' && !getVoiceSettings().enabled) send({ type: 'disable-voice' });
  }), [kit.mode]);
  const [demoAutoplay, setDemoAutoplay] = useState(true);
  const dispatch = useCallback((action: Action) => {
    if (kit.mode === 'demo') {
      if (action.type === 'demo-event' || action.type === 'demo-framing') setDemoAutoplay(false);
      if (action.type === 'retry' || action.type === 'sign-again' || action.type === 'resume') setDemoAutoplay(true);
    }
    send(action);
  }, [kit.mode]);
  const captureActive = canCapture(state);

  useEffect(() => {
    if (!state.expression || state.expression.status === 'stale') return;
    const observedAtMS = state.expression.observedAtMS;
    const timer = setTimeout(() => dispatch({ type: 'expire-expression', observedAtMS }),
      Math.max(0, observedAtMS + EXPRESSION_FRESH_MS - Date.now()));
    return () => clearTimeout(timer);
  }, [state.expression?.observedAtMS, state.expression?.status, dispatch]);

  useEffect(() => {
    if (!state.candidate) return;
    const { attemptId, expiresAtMS } = state.candidate;
    const timer = setTimeout(() => dispatch({ type: 'expire-candidate', attemptId }), Math.max(0, expiresAtMS - Date.now()));
    return () => clearTimeout(timer);
  }, [state.candidate?.attemptId, state.candidate?.expiresAtMS, dispatch]);

  useEffect(() => {
    if (!captureActive || state.framing !== 'ready' || (kit.mode === 'demo' && !demoAutoplay)) return;
    const captureId = state.captureId;
    return kit.translation.start(captureId, event => {
      // A finite sample ends when accepted. Opening sheets must not replace a correction or manual demo state.
      if (kit.mode === 'demo' && event.type === 'accepted') setDemoAutoplay(false);
      dispatch({ type: 'translation', event, captureId });
    });
  }, [captureActive, state.framing, state.captureId, kit, demoAutoplay, dispatch]);

  useEffect(() => {
    if (!state.speech) return;
    const request = state.speech;
    const controller = new AbortController();
    kit.voice.speak({ text: request.text, emotion: request.emotion }, controller.signal, () => {
      if (!controller.signal.aborted) dispatch({ type: 'speech-started', id: request.id });
    }).then(
      () => { if (!controller.signal.aborted) dispatch({ type: 'speech-ended', id: request.id }); },
      () => { if (!controller.signal.aborted) dispatch({ type: 'speech-ended', id: request.id, failed: true }); },
    );
    return () => controller.abort();
  }, [state.speech?.id, kit]);

  useEffect(() => {
    const subscription = AppState.addEventListener('change', next => {
      // A camera permission prompt briefly makes iOS inactive; it is not an explicit pause.
      if (next === 'background') dispatch({ type: 'pause' });
    });
    return () => subscription.remove();
  }, []);

  const onFraming = useCallback((framing: Framing, captureId: number) => {
    dispatch({ type: 'framing', framing, captureId });
  }, []);

  const onTranslation = useCallback((event: TranslationEvent, captureId: number) => {
    dispatch({ type: 'translation', event, captureId });
  }, [dispatch]);

  const onExpression = useCallback((event: ExpressionEvent) => dispatch({ type: 'expression', event }), [dispatch]);
  return { state, dispatch, captureActive, onFraming, onTranslation, onExpression };
}
