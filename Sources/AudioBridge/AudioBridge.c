#include "AudioBridge.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <math.h>

#define CAPACITY 32768u
struct SCBridge {
    float left[CAPACITY], right[CAPACITY];
    _Atomic unsigned long long written, read;
    _Atomic float gain, peak;
    double ratio, fraction;
    float currentGain;
};
SCBridge *SCBridgeCreate(double inputRate, double outputRate) {
    if (inputRate <= 0 || outputRate <= 0) return NULL;
    SCBridge *b = calloc(1, sizeof(SCBridge));
    if (b) { b->ratio = inputRate / outputRate; b->gain = 1; b->currentGain = 0; }
    return b;
}
void SCBridgeDestroy(SCBridge *b) { free(b); }
void SCBridgeSetGain(SCBridge *b, float gain) { atomic_store_explicit(&b->gain, fmaxf(0, fminf(1, gain)), memory_order_relaxed); }
unsigned long long SCBridgeReceived(SCBridge *b) { return atomic_load(&b->written); }
float SCBridgePeak(SCBridge *b) { return atomic_load_explicit(&b->peak, memory_order_relaxed); }
OSStatus SCBridgeCapture(AudioObjectID device, const AudioTimeStamp *now,
    const AudioBufferList *input, const AudioTimeStamp *inputTime,
    AudioBufferList *output, const AudioTimeStamp *outputTime, void *context) {
    SCBridge *b = context;
    if (!input || !input->mNumberBuffers) return noErr;
    const AudioBuffer *first = &input->mBuffers[0];
    if (!first->mData || !first->mNumberChannels) return noErr;
    unsigned frames = first->mDataByteSize / (sizeof(float) * first->mNumberChannels);
    const float *l = first->mData, *r = l;
    unsigned stride = first->mNumberChannels, rStride = stride, offset = stride > 1 ? 1 : 0;
    if (stride == 1 && input->mNumberBuffers > 1 && input->mBuffers[1].mData) {
        r = input->mBuffers[1].mData; rStride = input->mBuffers[1].mNumberChannels;
        unsigned rightFrames = input->mBuffers[1].mDataByteSize / (sizeof(float) * rStride);
        if (rightFrames < frames) frames = rightFrames;
    }
    unsigned long long w = atomic_load_explicit(&b->written, memory_order_relaxed);
    unsigned long long rd = atomic_load_explicit(&b->read, memory_order_acquire);
    float peak = 0;
    for (unsigned i = 0; i < frames && w - rd < CAPACITY; i++, w++) {
        float lv = l[i * stride], rv = r[i * rStride + offset];
        b->left[w % CAPACITY] = lv; b->right[w % CAPACITY] = rv;
        peak = fmaxf(peak, fmaxf(fabsf(lv), fabsf(rv)));
    }
    atomic_store_explicit(&b->peak, peak, memory_order_relaxed);
    atomic_store_explicit(&b->written, w, memory_order_release);
    return noErr;
}
void SCBridgeRender(SCBridge *b, AudioBufferList *output, unsigned frames) {
    unsigned long long rd = atomic_load_explicit(&b->read, memory_order_relaxed);
    unsigned long long w = atomic_load_explicit(&b->written, memory_order_acquire);
    // Bound latency after a device pause. Only the consumer advances the read cursor.
    if (w - rd > 8192) { rd = w - 2048; b->fraction = 0; }
    double ratio = b->ratio * (w - rd > 2048 ? 1.001 : (w - rd < 512 ? 0.999 : 1));
    float target = atomic_load_explicit(&b->gain, memory_order_relaxed);
    for (unsigned i = 0; i < frames; i++) {
        float l = 0, r = 0;
        b->currentGain += (target - b->currentGain) * 0.01f;
        if (rd + 1 < w) {
            unsigned a = rd % CAPACITY, next = (rd + 1) % CAPACITY;
            l = (b->left[a] + (b->left[next] - b->left[a]) * b->fraction) * b->currentGain;
            r = (b->right[a] + (b->right[next] - b->right[a]) * b->fraction) * b->currentGain;
            b->fraction += ratio;
            unsigned advance = (unsigned)b->fraction;
            if (advance > w - rd - 1) advance = (unsigned)(w - rd - 1);
            rd += advance; b->fraction -= floor(b->fraction);
        }
        unsigned channel = 0;
        for (unsigned j = 0; j < output->mNumberBuffers; j++) {
            AudioBuffer *buf = &output->mBuffers[j];
            if (!buf->mData || (i + 1) * buf->mNumberChannels * sizeof(float) > buf->mDataByteSize) continue;
            float *samples = buf->mData;
            for (unsigned c = 0; c < buf->mNumberChannels; c++, channel++)
                samples[i * buf->mNumberChannels + c] = channel == 0 ? l : (channel == 1 ? r : 0);
        }
    }
    atomic_store_explicit(&b->read, rd, memory_order_release);
}
