#if defined _beblock_voice_included
    #endinput
#endif
#define _beblock_voice_included

// Optional voice state owner. Callers must check the beblock library and native availability.
native bool BeBlock_IsVoiceBlocked(int listener, int speaker);
native bool BeBlock_SetVoiceBlocked(int listener, int speaker, bool blocked);

// Keeps consumers' fallback state in sync without rewriting the engine override.
forward void BeBlock_OnVoiceChanged(int listener, int speaker, bool blocked);
