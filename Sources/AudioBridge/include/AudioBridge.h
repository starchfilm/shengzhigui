#pragma once
#include <CoreAudio/CoreAudio.h>
#include <stdbool.h>

typedef struct SCBridge SCBridge;
SCBridge *SCBridgeCreate(double inputRate, double outputRate);
void SCBridgeDestroy(SCBridge *bridge);
void SCBridgeSetGain(SCBridge *bridge, float gain);
unsigned long long SCBridgeReceived(SCBridge *bridge);
float SCBridgePeak(SCBridge *bridge);
OSStatus SCBridgeCapture(AudioObjectID device, const AudioTimeStamp *now,
    const AudioBufferList *input, const AudioTimeStamp *inputTime,
    AudioBufferList *output, const AudioTimeStamp *outputTime, void *context);
void SCBridgeRender(SCBridge *bridge, AudioBufferList *output, unsigned int frames);
