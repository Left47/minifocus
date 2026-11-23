#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static IOUSBInterfaceInterface **usb;
static unsigned char terminal, interface_number;
static IOReturn transfer(int request, int selector, unsigned char *data, int size) {
    IOUSBDevRequest r = {0};
    r.bmRequestType = request == 1 ? 0x21 : 0xa1;
    r.bRequest = request;
    r.wValue = selector << 8;
    r.wIndex = (terminal << 8) | interface_number;
    r.wLength = size;
    r.pData = data;
    IOReturn rc = (*usb)->ControlRequest(usb, 0, &r);
    if (rc || (request != 1 && r.wLenDone != (unsigned)size)) {
        fprintf(stderr, "request=%02x selector=%02x rc=0x%08x bytes=%u\n", request, selector, rc, r.wLenDone);
        return rc ? rc : kIOReturnUnderrun;
    }
    return 0;
}
static int get(int request, int selector, int size, int *value) {
    unsigned char bytes[2] = {0};
    if (transfer(request, selector, bytes, size)) return 0;
    *value = bytes[0] | (size == 2 ? bytes[1] << 8 : 0);
    return 1;
}
static int set(int selector, int size, int value) {
    unsigned char bytes[2] = {value & 255, (value >> 8) & 255};
    return transfer(1, selector, bytes, size) == 0;
}
int main(int argc, char **argv) {
    io_iterator_t iterator;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &iterator)) return 1;
    io_service_t service;
    while ((service = IOIteratorNext(iterator))) {
        CFTypeRef name = IORegistryEntryCreateCFProperty(service, CFSTR("USB Product Name"), 0, 0);
        CFTypeRef subclass = IORegistryEntryCreateCFProperty(service, CFSTR("bInterfaceSubClass"), 0, 0);
        CFTypeRef cls = IORegistryEntryCreateCFProperty(service, CFSTR("bInterfaceClass"), 0, 0);
        int c = 0, s = 0;
        if (cls) CFNumberGetValue(cls, kCFNumberIntType, &c);
        if (subclass) CFNumberGetValue(subclass, kCFNumberIntType, &s);
        int match = name && CFEqual(name, CFSTR("Logitech Webcam C930e")) && c == 14 && s == 1;
        if (name) CFRelease(name);
        if (cls) CFRelease(cls);
        if (subclass) CFRelease(subclass);
        if (!match) { IOObjectRelease(service); continue; }
        IOCFPlugInInterface **plugin = NULL;
        SInt32 score;
        IOReturn rc = IOCreatePlugInInterfaceForService(service, kIOUSBInterfaceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
        IOObjectRelease(service);
        if (rc) { fprintf(stderr, "Plugin error 0x%08x\n", rc); return 1; }
        HRESULT hr = (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID), (void **)&usb);
        IODestroyPlugInInterface(plugin);
        if (hr || !usb) return 1;
        break;
    }
    IOObjectRelease(iterator);
    if (!usb) { fprintf(stderr, "C930e control interface not found\n"); return 1; }
    (*usb)->GetInterfaceNumber(usb, &interface_number);
    IOReturn opened = (*usb)->USBInterfaceOpen(usb);
    printf("Interface %u open: 0x%08x\n", interface_number, opened);
    // C930e camera terminal is probed read-only; no writes until controls read successfully.
    int auto_original = 0, focus_original = 0, found = 0;
    for (terminal = 1; terminal < 8; terminal++) {
        if (get(0x81, 8, 1, &auto_original) && get(0x81, 6, 2, &focus_original)) { found = 1; break; }
    }
    int result = 1;
    if (found) {
        int minimum, maximum, step, info;
        printf("Terminal %u: autofocus=%d focus=%d\n", terminal, auto_original, focus_original);
        if (get(0x82, 6, 2, &minimum) && get(0x83, 6, 2, &maximum) && get(0x84, 6, 2, &step) && get(0x86, 6, 1, &info)) {
            printf("Focus range: %d..%d step=%d capabilities=0x%02x\n", minimum, maximum, step, info);
            result = 0;
            if (argc == 2 && strcmp(argv[1], "--test") == 0) {
                int current = -1, auto_current = -1;
                int target = focus_original + (step > 0 ? step : 1);
                if (target > maximum) target = focus_original - (step > 0 ? step : 1);
                int ok = target >= minimum && target <= maximum && target != focus_original;
                // Always restore both settings after any attempted write.
                ok = ok && set(8, 1, 0);
                usleep(150000);
                ok = ok && get(0x81, 8, 1, &auto_current) && auto_current == 0;
                ok = ok && set(6, 2, target);
                usleep(300000);
                ok = ok && get(0x81, 6, 2, &current) && current == target;
                printf("Write test: requested=%d readback=%d autofocus=%d result=%s\n", target, current, auto_current, ok ? "PASS" : "FAIL");
                int restored = set(8, 1, 0);
                int focus_restored = set(6, 2, focus_original);
                restored = focus_restored && restored;
                usleep(150000);
                restored = get(0x81, 6, 2, &current) && current == focus_original && restored;
                restored = set(8, 1, auto_original) && restored;
                restored = get(0x81, 8, 1, &auto_current) && auto_current == auto_original && restored;
                printf("Restore: focus=%d autofocus=%d result=%s\n", current, auto_current, restored ? "PASS" : "FAIL");
                result = ok && restored ? 0 : 1;
            }
        }
    }
    if (opened == 0) (*usb)->USBInterfaceClose(usb);
    (*usb)->Release(usb);
    return result;
}
