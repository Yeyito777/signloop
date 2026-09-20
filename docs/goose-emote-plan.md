# Goose dance and emote implementation plan

First version implemented September 20, 2026: tap the goose on Home, in a conversation, or in the
standalone preview to play a three-second dance; tap again to stop. Separate dance
buttons have been removed. The implementation follows the plan below. Automatic phrase and sign
triggers remain optional future extensions.

The shared player lives in `goose/src/components/goose/emotes.ts` and
`goose/src/hooks/useGooseEmote.ts`. It uses a monotonic playback clock independent
of frame rate, ignores repeated request IDs, and settles requests even when the
canvas is paused or unavailable. Reduced motion acknowledges the action with a
short status message on Home; the conversation target is disabled. Route blur clears both the screen's request and the shared stage's
copy so returning from Settings cannot replay it.

## First experience

Start with a roughly three-second dance: the goose perks up, bobs its head,
alternates its wing flaps, gives a small body twist, and settles smoothly into
its current idle or listening pose. Keep the feet planted and all motion inside
the existing character frame. A wave and a bow can follow once the dance feels
good. Playback is local and can work offline.

| Time | Movement |
| --- | --- |
| 0–0.25 s | Ease into a slightly raised-wing pose. |
| 0.25–2.25 s | Two rhythmic body-bob and alternating-wing sequences, with gentle head tilt and body twist. |
| 2.25–2.65 s | Finish with both wings raised briefly. |
| 2.65–3 s | Blend into the current base pose. |

These timings are a starting point for visual tuning.

## Existing foundation

- `goose/src/components/goose/motion.ts` composes idle motion, activity,
  expression, and timed speech gestures, then clamps and blends the pose.
- `goose/src/components/goose/GooseScene.tsx` applies those poses to the head,
  wings, body, and beak. Feet sit outside the animated body root and stay fixed.
- `goose/src/screens/GoosePreview.tsx` provides the existing character preview.
- `mobile/src/integrations/GooseAvatar.tsx` adapts the same renderer for the app.
- `mobile/src/ui/SharedStage.tsx` keeps one goose mounted across Home and
  Conversation. Its visual layer ignores touches and is hidden from accessibility;
  an accessible trigger should live in the screen's normal control layer.

## Implementation order

1. **Define the action and its playback lifecycle.** Add an optional emote
   request carrying a unique request ID and an action name, initially `dance`.
   Keep this separate from activity and expression. A request plays once; ordinary
   rerenders cannot restart it. Completion and cancellation are associated with
   that ID so a late callback cannot clear a newer request.
2. **Add the choreography.** Create a pure emote pose sampler, driven by elapsed
   playback time, and compose its body/head/wing offsets with the base pose before
   clamping. Use an envelope that reaches zero at both ends and preserve the
   existing pose smoothing. Keep frame updates inside the current render loop.
   Reuse the existing pose limits for the first dance; evaluate larger motion
   separately. A genuine hop or step needs foot controls and shadow adjustments.
3. **Make it reviewable.** Make the goose tappable in the
   preview, with a playback status. First review the shared renderer in the web
   preview, then verify it in the Expo SDK 55 consumer app on an iPhone with the
   camera running. The standalone preview uses SDK 57; retain the consumer app's
   existing SDK and dependency choices.
4. **Connect the mobile app.** Pass the optional request and completion callback
   through `AvatarProps`, `StageSlot`/`SharedStageLayer`, `GooseAvatar`, `MrGoose`,
   and `GooseScene`. Add the chosen trigger in Home or Conversation. Preserve the
   shared renderer identity so an emote does not recreate the canvas.
5. **Verify interactions.** Cover single playback, deliberate replay, interruption,
   return to the current base pose, and reduced motion. Run the existing motion,
   gesture, presentation, and session checks plus both packages' type checks.

## Proposed playback rules

- Play one emote at a time. Ignore duplicate triggers while playing; preview
  Replay deliberately replaces the current request.
- Speech preparation or speech playback takes priority. Fade out/cancel a dance
  when either begins; do not delay voice or alter its beak/gesture timing.
- Cancel pending and active emotes when the session pauses, a sheet covers it,
  the app backgrounds, or the route owner changes. Returning must not replay an
  old request.
- With Reduce Motion enabled, acknowledge the action using a static pose or
  short status message and settle its request without waiting for animation
  frames. An animation-pause control must also leave no stuck request.
- Keep capture and recognition running during an emote when the session is
  otherwise active.

## Trigger decision

| Trigger | Integration |
| --- | --- |
| Tap the goose | Implemented: an accessible character-sized touch target on Home, in Conversation, and in the preview. A second tap stops playback; a later tap plays it again. Conversation disables the target during speech, pause, sheets, and reduced motion. |
| After a phrase | Trigger only after successful playback and when no next phrase is queued. Define which phrases deserve a reaction; avoid celebrating every utterance. |
| Recognized sign | Map an explicitly selected supported sign to the action and deduplicate by completed recognition attempt. Recognition support for a new sign would be separate work. |

All options should produce the same emote request. Choosing a trigger should not
require rewriting the animation.

## Review criteria

The dance has a visible beginning and finish, stays within the small phone stage,
and returns smoothly to the latest expression/activity. It can be replayed, never
stacks, and cancels cleanly. Voice gestures and lip sync still work. Backgrounding
and reduced motion do not leave it stuck. Confirm visual quality and responsiveness
on a physical iPhone with camera capture active; a web preview alone cannot settle
those checks.

## Verification completed

- Both packages pass `npm run typecheck`.
- Goose: 47 tests pass. Mobile: 94 tests pass, including the shared emote cases,
  after integrating with the latest `main`.
- Browser preview: rendered dance, replay, stop, pause cancellation, and automatic
  completion verified; no browser console errors observed.
- iPhone 17 Pro simulator: Home control, visible dance, completion, and leaving
  for Settings during playback verified. Returning Home keeps the dance stopped.
- Conversation in the simulator: tapping the character starts a visible dance;
  completion, replay, a second tap to stop, and pause cancellation verified.
  Resuming leaves the request cleared and re-enables the target.
- Physical-device performance with camera capture and actual voice playback
  remain unverified. Speech priority and preservation of lip sync/word gestures
  are covered by the automated pose/player checks.
