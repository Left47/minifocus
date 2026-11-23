#ifndef FOCUS_USB_H
#define FOCUS_USB_H
#include <stdint.h>
typedef struct FocusUSB FocusUSB;
typedef struct { int minimum, maximum, step, focus, automatic; uint32_t location; } FocusUSBState;
FocusUSB *focus_open(FocusUSBState *state, char *error, int capacity);
int focus_read(FocusUSB *, int *position, int *automatic);
int focus_manual(FocusUSB *);
int focus_write(FocusUSB *, int position);
int focus_restore(FocusUSB *);
void focus_close(FocusUSB *);
#endif
