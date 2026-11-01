#include "AudioBridge.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <math.h>

#define CAPACITY 32768u
#define TAPS 64u
#define PHASES 1024u
#define HISTORY 63u
struct SCBridge {
    float left[CAPACITY], right[CAPACITY];
    _Atomic unsigned long long written, read;
    _Atomic float gain, peak;
    double ratio, fraction;
    float currentGain;
    unsigned long long cursor;
    float kernel[PHASES + 1][TAPS];
};
SCBridge *SCBridgeCreate(double inputRate, double outputRate) {
    if (inputRate <= 0 || outputRate <= 0) return NULL;
    SCBridge *b = calloc(1, sizeof(SCBridge));
    if (b) {
        b->ratio = inputRate / outputRate; b->gain = 1; b->currentGain = 0;
        // Construct the band-limited interpolation table off the audio thread.
        const double pi = 3.14159265358979323846;
        double cutoff = b->ratio > 1 ? 0.94 / b->ratio : 1;
        for (unsigned phase = 0; phase <= PHASES; phase++) {
            double sum = 0;
            for (unsigned j = 0; j < TAPS; j++) {
                double x = (double)j - 31 - (double)phase / PHASES;
                double sinc = fabs(x) < 1e-12 ? cutoff : sin(pi * cutoff * x) / (pi * x);
                double window = fabs(x) >= 32 ? 0 : 0.42 + 0.5*cos(pi*x/32) + 0.08*cos(2*pi*x/32);
                b->kernel[phase][j] = (float)(sinc * window);
                sum += sinc * window;
            }
            for (unsigned j = 0; j < TAPS; j++) b->kernel[phase][j] /= (float)sum;
        }
    }
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
    unsigned long long rd = b->cursor;
    unsigned long long w = atomic_load_explicit(&b->written, memory_order_acquire);
    // Bound latency after a device pause. Only the consumer advances the read cursor.
    if (w - rd > 8192) { rd = w - 2048; b->fraction = 0; }
    // Thresholds scale with callback size. A normal 480-frame callback must not
    // be treated as starvation merely because it is smaller than 512 frames.
    double expected = fmax(1, frames * b->ratio);
    double ratio = b->ratio * (w - rd > expected * 4 ? 1.0001 : (w - rd < expected * 0.5 ? 0.9999 : 1));
    float target = atomic_load_explicit(&b->gain, memory_order_relaxed);
    for (unsigned i = 0; i < frames; i++) {
        float l = 0, r = 0;
        b->currentGain += (target - b->currentGain) * 0.01f;
        if (rd + 1 < w) {
            if (b->ratio == 1 && b->fraction == 0) {
                // Preserve an exact copy at unity rate, with the same fixed
                // 31-frame filter delay as the fractional-rate path.
                if (rd >= 31) {
                    unsigned a = (rd - 31) % CAPACITY;
                    l = b->left[a]; r = b->right[a];
                }
            } else {
                double phase = b->fraction * PHASES;
                unsigned p = (unsigned)phase;
                float blend = (float)(phase - p);
                for (unsigned j = 0; j < TAPS; j++) {
                    long long index = (long long)rd - 62 + j;
                    if (index < 0) continue;
                    float weight = b->kernel[p][j] + (b->kernel[p + 1][j] - b->kernel[p][j]) * blend;
                    unsigned a = (unsigned long long)index % CAPACITY;
                    l += b->left[a] * weight; r += b->right[a] * weight;
                }
            }
            l *= b->currentGain; r *= b->currentGain;
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
    b->cursor = rd;
    // Retain interpolation history until the consumer no longer needs it.
    atomic_store_explicit(&b->read, rd > HISTORY ? rd - HISTORY : 0, memory_order_release);
}
