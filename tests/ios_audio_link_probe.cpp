// Compile and link the actual mixer, CoreAudio backend, demuxers and decoders.
// This is a link probe, not evidence of sound output or an installable app.
#include <SDL2/SDL.h>
#include "native_audio.h"
#include <cstdio>
#include <initializer_list>
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libswresample/swresample.h>
}

int main() {
    const AVCodecID codecs[] = {AV_CODEC_ID_WMAV1, AV_CODEC_ID_WMAV2,
        AV_CODEC_ID_WMAPRO, AV_CODEC_ID_WMAVOICE, AV_CODEC_ID_ADPCM_MS,
        AV_CODEC_ID_PCM_S16LE, AV_CODEC_ID_PCM_S16BE, AV_CODEC_ID_PCM_F32LE};
    for (const auto codec : codecs)
        if (!avcodec_find_decoder(codec)) return 1;
    for (const char *format : {"xwma", "asf", "wav", "s16le"})
        if (!av_find_input_format(format)) return 2;
    if (!bo1_audio_supports(BO1_AUDIO_XWMA)) return 3;
    bool coreAudio = false;
    for (int index = 0; index < SDL_GetNumAudioDrivers(); ++index) {
        const char *driver = SDL_GetAudioDriver(index);
        std::printf("SDL audio driver: %s\n", driver);
        if (SDL_strcmp(driver, "coreaudio") == 0) coreAudio = true;
    }
    std::printf("FFmpeg: %s; swresample: %u\n", av_version_info(), swresample_version());
    return coreAudio ? 0 : 4;
}
