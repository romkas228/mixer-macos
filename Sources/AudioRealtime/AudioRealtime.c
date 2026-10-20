// Copyright (C) 2026 romkas228
// SPDX-License-Identifier: GPL-3.0-only

#include "AudioRealtime.h"
#include <libproc.h>
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct MixerRenderContext {
    _Atomic float targetGain;
    _Atomic unsigned long long callbacks;
    float currentGain;
    float rampStep;
    unsigned inputChannelOffset;
    unsigned outputChannels;
};

static float clampGain(float gain) {
    return isfinite(gain) ? fmaxf(0, fminf(1, gain)) : 1;
}

MixerRenderContext *MixerRenderContextCreate(float gain, double rate,
                                             unsigned offset, unsigned channels) {
    MixerRenderContext *c = calloc(1, sizeof(*c));
    if (!c) return NULL;
    atomic_init(&c->targetGain, clampGain(gain));
    atomic_init(&c->callbacks, 0);
    if (!atomic_is_lock_free(&c->targetGain) || !atomic_is_lock_free(&c->callbacks)) {
        free(c);
        return NULL;
    }
    c->rampStep = 1.0f / (float)(fmax(rate, 1) * 0.005); // 5 ms de-click ramp
    c->inputChannelOffset = offset;
    c->outputChannels = channels;
    return c;
}

void MixerRenderContextDestroy(MixerRenderContext *c) { free(c); }
void MixerRenderContextSetGain(MixerRenderContext *c, float gain) {
    atomic_store_explicit(&c->targetGain, clampGain(gain), memory_order_relaxed);
}
unsigned long long MixerRenderContextCallbackCount(MixerRenderContext *c) {
    return atomic_load_explicit(&c->callbacks, memory_order_relaxed);
}

OSStatus MixerCreateIOProc(AudioObjectID device, MixerRenderContext *context,
                          AudioDeviceIOProcID *proc) {
    return AudioDeviceCreateIOProcID(device, MixerRenderAudio, context, proc);
}

static OSStatus permissionIOProc(AudioObjectID device, const AudioTimeStamp *now,
                                 const AudioBufferList *input, const AudioTimeStamp *inputTime,
                                 AudioBufferList *output, const AudioTimeStamp *outputTime,
                                 void *context) {
    (void)device; (void)now; (void)input; (void)inputTime;
    (void)output; (void)outputTime; (void)context;
    return noErr;
}

OSStatus MixerCreatePermissionIOProc(AudioObjectID device, AudioDeviceIOProcID *proc) {
    return AudioDeviceCreateIOProcID(device, permissionIOProc, NULL, proc);
}

typedef struct {
    float *data;
    unsigned stride;
    unsigned frames;
} Channel;

static Channel channel(const AudioBufferList *list, unsigned index) {
    if (list) {
        for (unsigned b = 0; b < list->mNumberBuffers; ++b) {
            const AudioBuffer *buffer = &list->mBuffers[b];
            if (index < buffer->mNumberChannels) {
                if (!buffer->mData || !buffer->mNumberChannels) return (Channel){0};
                return (Channel){(float *)buffer->mData + index,
                                 buffer->mNumberChannels,
                                 buffer->mDataByteSize / sizeof(float) / buffer->mNumberChannels};
            }
            index -= buffer->mNumberChannels;
        }
    }
    return (Channel){0};
}

OSStatus MixerRenderAudio(AudioObjectID device, const AudioTimeStamp *now,
                        const AudioBufferList *input, const AudioTimeStamp *inputTime,
                        AudioBufferList *output, const AudioTimeStamp *outputTime,
                        void *context) {
    (void)device; (void)now; (void)inputTime; (void)outputTime;
    MixerRenderContext *c = context;
    // HAL normally supplies zeroed output; clear explicitly for safe format/size mismatch handling.
    for (unsigned b = 0; b < output->mNumberBuffers; ++b) {
        if (output->mBuffers[b].mData)
            memset(output->mBuffers[b].mData, 0, output->mBuffers[b].mDataByteSize);
    }
    Channel left = channel(input, c->inputChannelOffset);
    Channel right = channel(input, c->inputChannelOffset + 1);
    Channel outLeft = channel(output, 0);
    Channel outRight = channel(output, 1);
    unsigned frames = outLeft.frames;
    if (left.frames < frames) frames = left.frames;
    if (right.frames < frames) frames = right.frames;
    if (c->outputChannels > 1 && outRight.frames < frames) frames = outRight.frames;
    float target = atomic_load_explicit(&c->targetGain, memory_order_relaxed);
    float gain = c->currentGain;
    if (left.data && right.data && outLeft.data) {
        unsigned f = 0;
        // Ramp only while changing gain; the steady-state loop can be vectorized.
        for (; f < frames && gain != target; ++f) {
            float delta = target - gain;
            gain += fmaxf(-c->rampStep, fminf(c->rampStep, delta));
            float l = left.data[f * left.stride];
            float r = right.data[f * right.stride];
            if (c->outputChannels == 1) outLeft.data[f * outLeft.stride] = (l + r) * 0.5f * gain;
            else {
                outLeft.data[f * outLeft.stride] = l * gain;
                if (outRight.data) outRight.data[f * outRight.stride] = r * gain;
            }
        }
        // Muted buffers are already zero. Do not read or multiply their samples.
        if (gain != 0) {
            for (; f < frames; ++f) {
                float l = left.data[f * left.stride];
                float r = right.data[f * right.stride];
                if (c->outputChannels == 1) outLeft.data[f * outLeft.stride] = (l + r) * 0.5f * gain;
                else {
                    outLeft.data[f * outLeft.stride] = l * gain;
                    if (outRight.data) outRight.data[f * outRight.stride] = r * gain;
                }
            }
        }
    }
    c->currentGain = gain;
    atomic_fetch_add_explicit(&c->callbacks, 1, memory_order_relaxed);
    return noErr;
}

OSStatus MixerConfigureInputStreams(AudioObjectID device, AudioDeviceIOProcID proc,
                                   unsigned physicalStreamCount) {
    AudioObjectPropertyAddress address = {kAudioDevicePropertyStreams,
                                         kAudioObjectPropertyScopeInput, kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(device, &address, 0, NULL, &size);
    if (status != noErr) return status;
    unsigned count = size / sizeof(AudioStreamID);
    if (count <= physicalStreamCount) return kAudioHardwareBadStreamError;
    size_t bytes = offsetof(AudioHardwareIOProcStreamUsage, mStreamIsOn) + count * sizeof(UInt32);
    AudioHardwareIOProcStreamUsage *usage = calloc(1, bytes);
    if (!usage) return kAudioHardwareUnspecifiedError;
    usage->mIOProc = (void *)proc;
    usage->mNumberStreams = count;
    for (unsigned i = physicalStreamCount; i < count; ++i) usage->mStreamIsOn[i] = 1;
    address.mSelector = kAudioDevicePropertyIOProcStreamUsage;
    status = AudioObjectSetPropertyData(device, &address, 0, NULL, (UInt32)bytes, usage);
    free(usage);
    return status;
}

pid_t MixerParentPID(pid_t pid) {
    struct proc_bsdinfo info;
    int size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    return size == sizeof(info) ? (pid_t)info.pbi_ppid : 0;
}
