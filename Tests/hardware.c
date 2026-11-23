#include "FocusUSB.h"
#include <stdio.h>
int main(void) {
    FocusUSBState state = {0}; char error[512] = {0};
    FocusUSB *camera = focus_open(&state, error, sizeof(error));
    if (!camera) { fprintf(stderr, "%s\n", error); return 1; }
    int target = state.focus + state.step;
    if (target > state.maximum) target = state.focus - state.step;
    int position = -1, automatic = -1;
    int ok = focus_manual(camera) && focus_write(camera, target) && focus_read(camera, &position, &automatic) && position == target && automatic == 0;
    printf("USB write/readback: %s (original=%d target=%d actual=%d)\n", ok ? "PASS" : "FAIL", state.focus, target, position);
    int restored = focus_restore(camera);
    printf("Original settings restored: %s\n", restored ? "PASS" : "FAIL");
    focus_close(camera);
    return ok && restored ? 0 : 1;
}
