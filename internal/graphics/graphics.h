#ifndef SWIPT_GRAPHICS_H
#define SWIPT_GRAPHICS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct {
    void *image;
    size_t length;
    double scale;
    char *failure;
} swipt_graphics_screenshot;

typedef struct {
    uintptr_t feed;
    int64_t width;
    int64_t height;
    double scale;
    char *failure;
} swipt_graphics_screen;

void swipt_graphics_native(void *context, int32_t command, void *value, uint64_t engine);
void swipt_graphics_warm(void);
char *swipt_graphics_run(uint64_t engine, int64_t call, uintptr_t scope);
char *swipt_graphics_watch(uint64_t engine, int64_t call, uintptr_t scope);
void swipt_graphics_screen_packets(const void *bytes, size_t length);
void swipt_graphics_screen_ended(const char *failure);

#endif
