#if defined _readyup_external_included
 #endinput
#endif
#define _readyup_external_included

// An external round controller may publish ReadyUp notifications only while
// l4d_ready_enabled is 0. These calls never enable ReadyUp's gameplay controls.
// Consumers continue to use the existing readyup forwards and IsInReady().
native bool ReadyUp_ExternalBegin();
native bool ReadyUp_ExternalLive();
native void ReadyUp_ExternalCancel();
