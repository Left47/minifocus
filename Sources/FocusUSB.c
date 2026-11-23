#include "FocusUSB.h"
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

struct FocusUSB {
    IOUSBInterfaceInterface220 **interface;
    uint8_t number, terminal;
    int opened, changed;
    FocusUSBState original;
};
static int property(io_service_t service, CFStringRef key) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(service, key, 0, 0);
    int result = 0;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID()) CFNumberGetValue(value, kCFNumberIntType, &result);
    if (value) CFRelease(value);
    return result;
}
static int request(FocusUSB *u, int operation, int selector, int size, int *value) {
    uint8_t data[2] = {*value & 255, (*value >> 8) & 255};
    IOUSBDevRequest r = {0};
    r.bmRequestType = operation == 1 ? 0x21 : 0xa1;
    r.bRequest = operation; r.wValue = selector << 8;
    r.wIndex = (u->terminal << 8) | u->number;
    r.wLength = size; r.pData = data;
    IOReturn rc = (*u->interface)->ControlRequest(u->interface, 0, &r);
    if (rc || (operation != 1 && r.wLenDone != (unsigned)size)) return 0;
    if (operation != 1) *value = data[0] | (size == 2 ? data[1] << 8 : 0);
    return 1;
}
int focus_read(FocusUSB *u, int *position, int *automatic) {
    return request(u, 0x81, 6, 2, position) && request(u, 0x81, 8, 1, automatic);
}
FocusUSB *focus_open(FocusUSBState *state, char *error, int capacity) {
    io_iterator_t iterator = 0; io_service_t service, selected = 0; int count = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &iterator)) {
        snprintf(error, capacity, "Cannot enumerate USB interfaces."); return NULL;
    }
    while ((service = IOIteratorNext(iterator))) {
        if (property(service, CFSTR("idVendor")) == 0x046d && property(service, CFSTR("idProduct")) == 0x0843 &&
            property(service, CFSTR("bInterfaceClass")) == 14 && property(service, CFSTR("bInterfaceSubClass")) == 1) {
            count++; if (!selected) { selected = service; continue; }
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    if (count != 1) {
        if (selected) IOObjectRelease(selected);
        snprintf(error, capacity, "Connect exactly one Logitech C930e. Found %d.", count); return NULL;
    }
    FocusUSB *u = calloc(1, sizeof(*u));
    if (!u) { IOObjectRelease(selected); return NULL; }
    u->original.location = (uint32_t)property(selected, CFSTR("locationID"));
    IOCFPlugInInterface **plugin = NULL; SInt32 score = 0;
    IOReturn rc = IOCreatePlugInInterfaceForService(selected, kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    IOObjectRelease(selected);
    if (rc || !plugin) { snprintf(error, capacity, "USB access failed (0x%08x). Run the app outside a sandbox.", rc); free(u); return NULL; }
    HRESULT hr = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID220), (void **)&u->interface);
    IODestroyPlugInInterface(plugin);
    if (hr || !u->interface) { snprintf(error, capacity, "Cannot access the USB camera controls."); free(u); return NULL; }
    (*u->interface)->GetInterfaceNumber(u->interface, &u->number);
    rc = (*u->interface)->USBInterfaceOpen(u->interface);
    u->opened = rc == 0;
    // macOS's camera driver may already own the interface. Control requests can
    // still work; never seize it away from the driver or OBS.
    IOUSBDescriptorHeader *descriptor = NULL;
    while ((descriptor = (*u->interface)->FindNextAssociatedDescriptor(u->interface, descriptor, 0x24))) {
        const uint8_t *d = (const uint8_t *)descriptor;
        if (d[0] >= 15 && d[2] == 2 && d[4] == 1 && d[5] == 2) { u->terminal = d[3]; break; }
    }
    int info = 0;
    if (!u->terminal || !focus_read(u, &u->original.focus, &u->original.automatic) ||
        !request(u, 0x82, 6, 2, &u->original.minimum) || !request(u, 0x83, 6, 2, &u->original.maximum) ||
        !request(u, 0x84, 6, 2, &u->original.step) || !request(u, 0x86, 6, 1, &info) || !(info & 2) ||
        u->original.step < 1 || u->original.maximum <= u->original.minimum) {
        snprintf(error, capacity, "Camera did not expose readable and writable focus controls."); focus_close(u); return NULL;
    }
    *state = u->original;
    return u;
}
int focus_manual(FocusUSB *u) {
    int value = 0, verify = -1;
    u->changed = 1;
    return request(u, 1, 8, 1, &value) && request(u, 0x81, 8, 1, &verify) && verify == 0;
}
int focus_write(FocusUSB *u, int position) {
    if (position < u->original.minimum || position > u->original.maximum ||
        (position - u->original.minimum) % u->original.step) return 0;
    u->changed = 1;
    int verify = -1;
    return request(u, 1, 6, 2, &position) && request(u, 0x81, 6, 2, &verify) && verify == position;
}
int focus_restore(FocusUSB *u) {
    if (!u || !u->changed) return 1;
    int zero = 0, focus = u->original.focus, automatic = u->original.automatic;
    int ok = request(u, 1, 8, 1, &zero);
    int f = request(u, 1, 6, 2, &focus);
    int a = request(u, 1, 8, 1, &automatic);
    int actualFocus = -1, actualAuto = -1;
    int read = focus_read(u, &actualFocus, &actualAuto);
    // With native autofocus restored, the driver is free to move the lens.
    ok = ok && f && a && read && actualAuto == automatic && (automatic || actualFocus == focus);
    if (ok) u->changed = 0;
    return ok;
}
void focus_close(FocusUSB *u) {
    if (!u) return;
    if (u->interface) {
        focus_restore(u);
        if (u->opened) (*u->interface)->USBInterfaceClose(u->interface);
        (*u->interface)->Release(u->interface);
    }
    free(u);
}
