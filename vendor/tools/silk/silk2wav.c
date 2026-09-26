/* silk2wav.c — 微信 SILK 语音 → WAV(24kHz PCM16LE mono, 供 whisper.cpp 再转 16k)
 * 基于 kn007/silk-v3-decoder(SILK SDK, Skype Limited 版权头随源码保留)。
 * 用法: silk2wav input.silk output.wav
 * 成功时 stdout 最后一行: "时长秒 包数", 退出码 0; 无有效音频退出码 2。
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "SKP_Silk_SDK_API.h"

#define MAX_BYTES_PER_FRAME 1024
#define MAX_INPUT_FRAMES    5
#define FRAME_LENGTH_MS     20
#define SAMPLE_RATE_HZ      24000

int main(int argc, char *argv[]) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s input.silk output.wav\n", argv[0]);
        return 1;
    }

    FILE *in = fopen(argv[1], "rb");
    if (!in) {
        fprintf(stderr, "error: cannot open %s\n", argv[1]);
        return 1;
    }

    /* 文件头可能是 "#!SILK_V3"(9B)、"!SILK_V3"(8B) 或无(直接 payload)。 */
    {
        char probe[16];
        size_t got = fread(probe, 1, sizeof(probe), in);
        if (got >= 9 && memcmp(probe, "#!SILK_V3", 9) == 0) {
            fseek(in, 9, SEEK_SET);
        } else if (got >= 8 && memcmp(probe, "!SILK_V3", 8) == 0) {
            fseek(in, 8, SEEK_SET);
        } else {
            fseek(in, 0, SEEK_SET);
        }
    }

    SKP_SILK_SDK_DecControlStruct ctrl;
    SKP_int32 decSize = 0;
    SKP_Silk_SDK_Get_Decoder_Size(&decSize);
    void *dec = malloc((size_t)decSize);
    if (!dec) {
        fprintf(stderr, "error: out of memory\n");
        return 1;
    }
    ctrl.API_sampleRate = SAMPLE_RATE_HZ;
    ctrl.framesPerPacket = 1;
    SKP_Silk_SDK_InitDecoder(dec);

    FILE *out = fopen(argv[2], "wb");
    if (!out) {
        fprintf(stderr, "error: cannot open %s\n", argv[2]);
        return 1;
    }
    /* 先占位 44 字节 WAV 头 */
    {
        unsigned char hdr44[44];
        memset(hdr44, 0, sizeof(hdr44));
        fwrite(hdr44, 1, sizeof(hdr44), out);
    }

    SKP_int16 outBuf[FRAME_LENGTH_MS * SAMPLE_RATE_HZ / 1000 * (MAX_INPUT_FRAMES + 1)];
    long pcmSamples = 0;
    long packets = 0;

    while (1) {
        SKP_int16 nb = 0;
        if (fread(&nb, sizeof(SKP_int16), 1, in) != 1) break;
        if (nb < 0) break;

        SKP_uint8 p[MAX_BYTES_PER_FRAME];
        int havePayload = 0;
        if (nb > 0) {
            if ((size_t)nb > sizeof(p)) nb = (SKP_int16)sizeof(p);
            if (fread(p, 1, (size_t)nb, in) != (size_t)nb) break;
            havePayload = 1;
        }

        SKP_int16 *o = outBuf;
        SKP_int16 tot = 0;
        if (havePayload) {
            int frames = 0;
            do {
                SKP_int16 len = 0;
                SKP_Silk_SDK_Decode(dec, &ctrl, 0, p, nb, o, &len);
                o += len;
                tot += len;
                frames++;
            } while (ctrl.moreInternalDecoderFrames && frames <= MAX_INPUT_FRAMES);
        } else {
            /* 丢包: 生成 20ms 丢失补偿 */
            SKP_int16 len = 0;
            SKP_Silk_SDK_Decode(dec, &ctrl, 1, p, 0, o, &len);
            tot += len;
        }
        if (tot > 0) {
            fwrite(outBuf, sizeof(SKP_int16), (size_t)tot, out);
            pcmSamples += tot;
        }
        packets++;
    }

    /* 回填 WAV 头 */
    {
        unsigned int dataBytes = (unsigned int)(pcmSamples * sizeof(SKP_int16));
        unsigned int chunkSize = 36 + dataBytes;
        unsigned short fmtTag = 1, channels = 1, blockAlign = 2, bitsPerSample = 16;
        unsigned int sr = SAMPLE_RATE_HZ;
        unsigned int byteRate = sr * channels * bitsPerSample / 8;
        unsigned char w[44];
        int pos = 0;
        memcpy(w + pos, "RIFF", 4); pos += 4;
        memcpy(w + pos, &chunkSize, 4); pos += 4;
        memcpy(w + pos, "WAVE", 4); pos += 4;
        memcpy(w + pos, "fmt ", 4); pos += 4;
        unsigned int fmtLen = 16;
        memcpy(w + pos, &fmtLen, 4); pos += 4;
        memcpy(w + pos, &fmtTag, 2); pos += 2;
        memcpy(w + pos, &channels, 2); pos += 2;
        memcpy(w + pos, &sr, 4); pos += 4;
        memcpy(w + pos, &byteRate, 4); pos += 4;
        memcpy(w + pos, &blockAlign, 2); pos += 2;
        memcpy(w + pos, &bitsPerSample, 2); pos += 2;
        memcpy(w + pos, "data", 4); pos += 4;
        memcpy(w + pos, &dataBytes, 4); pos += 4;
        fseek(out, 0, SEEK_SET);
        fwrite(w, 1, 44, out);
    }

    fclose(out);
    fclose(in);
    free(dec);

    double secs = (double)pcmSamples / SAMPLE_RATE_HZ;
    printf("%.3f %ld\n", secs, packets);
    return pcmSamples > 0 ? 0 : 2;
}
