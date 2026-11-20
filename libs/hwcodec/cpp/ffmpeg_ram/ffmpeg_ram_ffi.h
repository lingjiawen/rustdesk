#ifndef FFMPEG_RAM_FFI_H
#define FFMPEG_RAM_FFI_H

#include <stdint.h>

#define AV_NUM_DATA_POINTERS 8

// The pixfmt a decode callback gets for a frame that is still on the GPU: no
// planes are given, and data[3] is the platform's handle to it (a
// CVPixelBufferRef with VideoToolbox), valid until the callback returns.
#define FFMPEG_RAM_PIXFMT_NATIVE -100

typedef void (*RamDecodeCallback)(const void *obj, int width, int height,
                                  int pixfmt,
                                  int linesize[AV_NUM_DATA_POINTERS],
                                  uint8_t *data[AV_NUM_DATA_POINTERS], int key);
typedef void (*RamEncodeCallback)(const uint8_t *data, int len, int64_t pts,
                                  int key, const void *obj);

void *ffmpeg_ram_new_encoder(const char *name, const char *mc_name, int width,
                             int height, int pixfmt, int align, int fps,
                             int gop, int rc, int quality, int kbs, int q,
                             int thread_count, int gpu, int *linesize,
                             int *offset, int *length,
                             RamEncodeCallback callback);
void *ffmpeg_ram_new_decoder(const char *name, int device_type,
                             int thread_count, RamDecodeCallback callback);
int ffmpeg_ram_encode(void *encoder, const uint8_t *data, int length,
                      const void *obj, int64_t ms);
int ffmpeg_ram_decode(void *decoder, const uint8_t *data, int length,
                      const void *obj);
void ffmpeg_ram_free_encoder(void *encoder);
void ffmpeg_ram_free_decoder(void *decoder);
int ffmpeg_ram_get_linesize_offset_length(int pix_fmt, int width, int height,
                                          int align, int *linesize, int *offset,
                                          int *length);
int ffmpeg_ram_set_bitrate(void *encoder, int kbs);
// Makes the next frame given to the encoder a key frame.
void ffmpeg_ram_request_keyframe(void *encoder);
// With VideoToolbox, hands decoded frames out as they are on the GPU instead of
// downloading them, see FFMPEG_RAM_PIXFMT_NATIVE.
void ffmpeg_ram_decoder_native_frames(void *decoder, int on);

#endif // FFMPEG_RAM_FFI_H