# PersonaPlex Architecture and Training Plan

## Scope

This document describes the **PersonaPlex** system only: its real-time
conversation stack, its connection to an external LLM, and the separate data
and training stages needed to improve conversational behavior and a final
assistant voice.

PersonaPlex is a speech-first, full-duplex model. Its strength is not broad
general reasoning; its strength is natural timing: listening while speaking,
handling interruption, backchanneling, and sustaining a believable voice
persona. A stronger external LLM can supply reasoning, memory, tools, and
facts without replacing that real-time speech layer.

## Current inference architecture

```text
Browser microphone
       │  WebSocket /api/chat
       ▼
Nginx :7860
       ▼
PersonaPlex / Moshi server
       ├── Mimi encoder: PCM audio → streaming speech tokens
       ├── Moshi / Helium language model: conversational state and generation
       ├── Mimi decoder: generated speech tokens → PCM audio
       └── text-token stream: assistant text displayed in the browser
       ▼
Browser audio playback
```

The deployed server is a single real-time model process behind Nginx. The
browser sends microphone audio and receives Opus audio plus generated assistant
text. The deployed model assets are cached on the persistent Verda disk.

### Live context

The current Moshi language model uses a 3,000-step streaming attention cache at
12.5 time steps per second: about four minutes of rolling live context. Older
audio/text state is overwritten as the ring cache advances. This bounded cache
is part of why low latency remains practical.

## Model components

| Component | Job | Train separately? |
|---|---|---|
| Mimi audio codec | Converts waveform to/from speech tokens | Normally frozen |
| Moshi / Helium LM | Turn-taking, language, text/speech token generation | Yes, via a conservative adapter or LoRA |
| Voice conditioning | Selects a target assistant voice/persona | Yes, after duplex behavior is stable |
| Browser + WebSocket server | Captures/plays audio and transports events | Engineering change, not model training |
| External LLM | Long context, reasoning, retrieval, tools | Usually an independent model/service |
| Bridge | Turns LLM decisions into safe real-time controls | Engineering first; optional adapter later |

Do not attempt to directly pass vLLM embeddings into Moshi. Their tokenizers,
hidden-state spaces, and speech-token representations are unrelated. The
bridge must use a semantic control interface, not raw embeddings.

## External-LLM bridge

The external LLM owns long-term memory and intelligence. PersonaPlex owns
immediate speech timing.

```text
User audio ──> PersonaPlex live stream ──> natural listen/backchannel behavior
       │
       └──> bridge ──> external LLM
                         transcript/state/memory/tools
                                  │
                                  ▼
                         compact policy decision
                                  │
                                  ▼
                         PersonaPlex control layer
```

The LLM returns a compact, schema-validated decision such as:

```json
{
  "action": "speak",
  "intent": "Explain the GPU scheduling issue in one warm sentence.",
  "facts": ["The selected spot GPU has no available nodes."],
  "style": "calm, concise, conversational",
  "allow_interruption": true
}
```

The bridge keeps the complete transcript, retrieved documents, user memory,
and tool outputs. PersonaPlex receives a short instruction only when it is
needed to respond.

### Current limitation

The current browser protocol defines controls named `start`, `endTurn`,
`pause`, and `restart`, but the current server receive loop processes audio
packets only. It accepts `text_prompt` at WebSocket connection setup, not as a
dynamic per-turn instruction. Therefore, the following are engineering tasks,
not existing features:

- add a server-side control channel;
- add output gating / forced-listen behavior;
- add a safe per-session intent update mechanism;
- expose turn state to the bridge;
- prevent shared-state leakage across concurrent sessions.

### First bridge API

The first version should add deterministic commands to the PersonaPlex server:

```text
force_listen     suppress assistant output while the user has the floor
allow_speak      permit the next assistant response
end_turn         explicit user/bridge turn boundary
set_intent       short, validated semantic instruction
reset_session    clear live state and begin a new context
```

`force_listen` and output gating should be runtime controls, not behavior left
solely to model probability. The LLM should prepare an answer continuously but
the bridge decides when it may be spoken.

## Training architecture

There are separate training objectives. Do not combine all available audio into
one run.

### Run 0 — Baseline and evaluation

Start from the existing PersonaPlex checkpoint. Establish a fixed evaluation
suite before changing weights:

- response-start latency;
- false interruption rate;
- success rate when a user interrupts the assistant;
- talking-over-user rate;
- backchannel appropriateness;
- persona consistency;
- speech quality and voice stability.

This baseline protects the property that matters most: natural low-latency
duplex interaction.

### Run 1 — Duplex conversation adaptation

**Purpose:** teach or adapt conversational timing, language, and interaction.

**Data:** synchronized two-speaker conversations with a shared clock.

```text
conversation_001/
  user.flac              full duration; silence retained
  assistant.flac         full duration; silence retained
  mix.flac               optional reference mix
  timeline.jsonl         speaker + start/end + reviewed text
  metadata.json          language, roles, source/license, quality flags
```

Example timeline:

```json
{"speaker":"user","start_ms":0,"end_ms":2100,"text":"Can you explain it again?"}
{"speaker":"assistant","start_ms":2350,"end_ms":4700,"text":"Of course, the main point is..."}
{"speaker":"user","start_ms":3900,"end_ms":4500,"text":"Wait, which GPU?"}
```

The overlap is intentional. Do not concatenate speaker turns or remove shared
silence. The model must see when the user is still talking, when a pause is
long enough to answer, and how an answer is cut off by interruption.

The training pipeline converts both waveforms to the model's speech-token
representation and trains next-token prediction over the shared timeline:

```text
user speech tokens + control/persona condition
       → assistant text tokens + assistant speech tokens
```

Use a LoRA or other parameter-efficient adapter first. Freeze the codec and
most base layers until evaluation proves a wider fine-tune is necessary.

### Run 2 — Final assistant-voice specialization

**Purpose:** establish a stable final assistant voice without losing the
duplex behavior from Run 1.

**Data:** clean recordings of the selected assistant speaker, plus a retained
mixture of high-quality duplex examples from Run 1.

Single-speaker voice records look like:

```json
{
  "audio": "speaker_clip.flac",
  "text": "Reviewed transcript of what was spoken.",
  "speaker": "target_assistant",
  "voice_condition": "target_assistant",
  "language": "en"
}
```

Single-speaker audio teaches voice identity, pronunciation, prosody, pace, and
speech quality. It does **not** teach turn-taking. Fine-tuning only on
monologues after Run 1 would risk catastrophic forgetting: the checkpoint may
sound good while losing interruption behavior.

For this reason Run 2 uses a lower learning rate and mixes duplex examples into
every epoch. Voice specialization should be narrow and continuously checked
against Run 0's latency and interruption tests.

### Run 3 — Optional LLM-control conditioning

**Purpose:** improve how naturally PersonaPlex follows a short external
instruction such as intent, facts, style, or `listen`/`speak` policy.

**Data:** the same synchronized duplex conversations, augmented with compact
control annotations:

```json
{
  "action": "speak",
  "intent": "Clarify before offering a fix.",
  "facts": ["The requested GPU is currently unavailable."],
  "style": "warm and brief"
}
```

The target remains the natural assistant text/audio response. Train a small
conditioning adapter or LoRA, not a direct embedding splice from the external
LLM. Runtime `force_listen` and interruption gating remain deterministic
server/bridge controls even after this training.

## Single-speaker versus duplex data

| Property | Single-speaker voice data | Duplex conversation data |
|---|---|---|
| Main purpose | Voice identity and speech quality | Timing and interaction behavior |
| Audio form | Clean independent clip | Two synchronized full-duration tracks/windows |
| Silence between turns | Often trimmed | Must remain on shared timeline |
| Transcript | Text-to-speech target | Speaker- and time-attributed dialogue |
| Speaker roles | One target voice | Explicit user and assistant roles |
| Teaches interruption | No | Yes |
| Best training stage | Run 2 | Run 1 and Run 3 |

Both are necessary for a polished assistant. Duplex data makes it behave like a
conversational partner; final-voice data makes it sound like the intended
person.

## Podcast ingestion rules

Podcasts are useful raw material when the recordings are licensed/permissioned
and clean. Process them in this order:

```text
archive original episode
→ extract lossless master audio
→ diarize speakers on the master
→ mark music, noise, crosstalk, and overlap
→ make same-speaker transcription chunks with absolute offsets
→ transcribe and align
→ construct clean synchronized two-speaker windows
→ manual quality review and versioned manifests
```

Three or four speakers across an episode are acceptable. Build early training
windows only from clear two-person exchanges. Exclude heavy three- or four-way
simultaneous crosstalk unless clean isolated speaker tracks are available.

Do not randomly splice before diarization. For transcription, create
same-speaker chunks at natural silence boundaries and retain original time
offsets. For duplex training, rebuild longer 20–90 second shared-timeline
windows that include natural pauses and brief overlap.

## Latency target

The bridge must not turn PersonaPlex into a request/response voice bot.

- Output gating / forced listen: approximately immediate at the server level.
- External LLM: begin speculative reasoning on partial context; do not wait for
  a long answer or chain-of-thought.
- Response start after a real completed turn: target roughly 0.8–2.0 seconds,
  depending on model, network, and GPU load.
- While reasoning, PersonaPlex may provide a short natural acknowledgment only
  if the conversation policy permits it.

## Release gates

Promote a new PersonaPlex checkpoint only when it meets both speech and
conversation gates on held-out, source-disjoint data:

- no material first-response latency regression;
- no higher talking-over-user rate;
- reliable response to interruption;
- stable selected voice;
- transcript intelligibility;
- role/persona consistency;
- language-specific evaluation where new languages are added;
- no leakage between source episode/session and evaluation splits.

## Recommended sequence

1. Implement the bridge/server control interface and evaluate it with the
   unmodified PersonaPlex checkpoint.
2. Build a high-quality two-speaker synchronized corpus and run duplex
   adaptation.
3. Validate timing and interruption behavior.
4. Add the final single-speaker assistant-voice specialization while retaining
   duplex-data replay.
5. Add control-conditioning training only if the bridge's short prompts are not
   followed reliably enough.

This order keeps latency, voice quality, conversation behavior, and external
LLM intelligence independently measurable.
