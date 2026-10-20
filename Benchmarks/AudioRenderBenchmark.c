// Copyright (C) 2026 romkas228
// SPDX-License-Identifier: GPL-3.0-only

#include "AudioRealtime.h"
#include <mach/mach_time.h>
#include <stdio.h>
#include <stdlib.h>

enum { iterations = 100000, repetitions = 7 };

static int compare(const void *a, const void *b) {
    double left = *(const double *)a, right = *(const double *)b;
    return (left > right) - (left < right);
}

static AudioBufferList *buffers(unsigned count, unsigned channels, unsigned frames) {
    AudioBufferList *list = calloc(1, offsetof(AudioBufferList, mBuffers) + count * sizeof(AudioBuffer));
    if (!list) exit(1);
    list->mNumberBuffers = count;
    for (unsigned b = 0; b < count; ++b) {
        list->mBuffers[b].mNumberChannels = channels;
        list->mBuffers[b].mDataByteSize = frames * channels * sizeof(float);
        list->mBuffers[b].mData = calloc(frames * channels, sizeof(float));
        if (!list->mBuffers[b].mData) exit(1);
        for (unsigned f = 0; f < frames * channels; ++f)
            ((float *)list->mBuffers[b].mData)[f] = (float)((int)(f % 31) - 15) / 32;
    }
    return list;
}

static void destroy(AudioBufferList *list) {
    for (unsigned b = 0; b < list->mNumberBuffers; ++b) free(list->mBuffers[b].mData);
    free(list);
}

int main(void) {
    mach_timebase_info_data_t clock;
    mach_timebase_info(&clock);
    const unsigned sizes[] = {64, 128, 512};
    const float gains[] = {0, 0.5f, 1};
    printf("{\"scope\":\"synthetic C callback only; no HAL, devices, Swift or UI\",\"sampleRate\":48000,\"iterationsPerRepetition\":%d,\"repetitions\":%d,\"cases\":[\n", iterations, repetitions);
    int first = 1;
    for (unsigned format = 0; format < 3; ++format) {
        for (unsigned size = 0; size < 3; ++size) {
            unsigned frames = sizes[size];
            AudioBufferList *input = buffers(format == 1 ? 1 : 2, format == 1 ? 2 : 1, frames);
            AudioBufferList *output = buffers(format == 0 ? 2 : 1, format == 1 ? 2 : 1, frames);
            for (unsigned g = 0; g < 3; ++g) {
                MixerRenderContext *context = MixerRenderContextCreate(gains[g], 48000, 0, format == 2 ? 1 : 2);
                if (!context) return 1;
                // Warm caches and finish the initial 5 ms gain ramp before timing.
                for (unsigned warm = 0; warm < 1000; ++warm)
                    MixerRenderAudio(0, NULL, input, NULL, output, NULL, context);
                double measurements[repetitions];
                for (unsigned r = 0; r < repetitions; ++r) {
                    uint64_t start = mach_absolute_time();
                    for (unsigned i = 0; i < iterations; ++i)
                        MixerRenderAudio(0, NULL, input, NULL, output, NULL, context);
                    uint64_t end = mach_absolute_time();
                    measurements[r] = (double)(end - start) * clock.numer / clock.denom / iterations;
                }
                qsort(measurements, repetitions, sizeof(double), compare);
                double median = measurements[repetitions / 2];
                printf("%s{\"format\":\"%s\",\"frames\":%u,\"gain\":%.1f,\"medianNanosecondsPerCallback\":%.3f,\"minNanosecondsPerCallback\":%.3f,\"maxNanosecondsPerCallback\":%.3f,\"estimatedOneCorePercentForCallbackOnly\":%.6f}",
                       first ? "" : ",\n", format == 0 ? "planar-stereo" : format == 1 ? "interleaved-stereo" : "mono-downmix",
                       frames, gains[g], median, measurements[0], measurements[repetitions - 1], median * 48000 / frames / 1e7);
                first = 0;
                MixerRenderContextDestroy(context);
            }
            destroy(input);
            destroy(output);
        }
    }
    puts("\n]}");
    return 0;
}
