// Copyright (C) 2026 romkas228
// SPDX-License-Identifier: GPL-3.0-only

#ifndef MIXER_AUDIO_REALTIME_H
#define MIXER_AUDIO_REALTIME_H

#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>
#include <sys/types.h>
#include "ProcessMetrics.h"

typedef struct MixerRenderContext MixerRenderContext;

// All allocation and configuration happen before AudioDeviceStart.
MixerRenderContext *MixerRenderContextCreate(float gain, double sampleRate,
                                             unsigned inputChannelOffset,
                                             unsigned outputChannels);
void MixerRenderContextDestroy(MixerRenderContext *context);
void MixerRenderContextSetGain(MixerRenderContext *context, float gain);
unsigned long long MixerRenderContextCallbackCount(MixerRenderContext *context);
OSStatus MixerCreateIOProc(AudioObjectID device, MixerRenderContext *context,
                          AudioDeviceIOProcID *proc);
// A permission-only input callback: never reads, records or replays audio.
OSStatus MixerCreatePermissionIOProc(AudioObjectID device, AudioDeviceIOProcID *proc);
OSStatus MixerRenderAudio(AudioObjectID device, const AudioTimeStamp *now,
                        const AudioBufferList *input, const AudioTimeStamp *inputTime,
                        AudioBufferList *output, const AudioTimeStamp *outputTime,
                        void *context);

// Disable physical-device input streams; only read the appended process tap.
OSStatus MixerConfigureInputStreams(AudioObjectID device, AudioDeviceIOProcID proc,
                                   unsigned physicalStreamCount);
pid_t MixerParentPID(pid_t pid);

#endif
