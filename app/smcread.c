// Minimal AppleSMC key reader (independent implementation of the public SMC ABI)
// MIT License
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

typedef struct { char major, minor, build, reserved; uint16_t release; } SMCVers;
typedef struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } SMCPLimit;
typedef struct { uint32_t dataSize; uint32_t dataType; char dataAttributes; } SMCKeyInfo;
typedef struct {
    uint32_t key;
    SMCVers vers;
    SMCPLimit pLimit;
    SMCKeyInfo keyInfo;
    char result;
    char status;
    char data8;
    uint32_t data32;
    char bytes[32];
} SMCKeyData;

#define KERNEL_INDEX_SMC      2
#define SMC_CMD_READ_BYTES    5
#define SMC_CMD_READ_KEYINFO  9

static io_connect_t conn = 0;

static int smc_open(void) {
    io_service_t svc = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return -1;
    kern_return_t r = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    IOObjectRelease(svc);
    return r == KERN_SUCCESS ? 0 : -2;
}

static uint32_t key4(const char *s) {
    return ((uint32_t)(uint8_t)s[0] << 24) | ((uint32_t)(uint8_t)s[1] << 16) |
           ((uint32_t)(uint8_t)s[2] << 8) | (uint32_t)(uint8_t)s[3];
}

static int smc_read(const char *key, SMCKeyData *val) {
    SMCKeyData in;
    memset(&in, 0, sizeof(in));
    in.key = key4(key);
    in.data8 = SMC_CMD_READ_KEYINFO;
    size_t outSize = sizeof(in);
    kern_return_t r = IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, &in, sizeof(in), &in, &outSize);
    if (r != KERN_SUCCESS) return (int)r;

    SMCKeyData rd;
    memset(&rd, 0, sizeof(rd));
    rd.key = key4(key);
    rd.keyInfo = in.keyInfo;
    rd.data8 = SMC_CMD_READ_BYTES;
    outSize = sizeof(rd);
    r = IOConnectCallStructMethod(conn, KERNEL_INDEX_SMC, &rd, sizeof(rd), val, &outSize);
    return (int)r;
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: smcread KEY\n"); return 2; }
    if (smc_open() != 0) { fprintf(stderr, "cannot open AppleSMC\n"); return 3; }
    SMCKeyData v;
    memset(&v, 0, sizeof(v));
    int r = smc_read(argv[1], &v);
    if (r != 0) { fprintf(stderr, "read failed 0x%x\n", r); return 4; }
    char type[5] = { (char)(v.keyInfo.dataType >> 24), (char)(v.keyInfo.dataType >> 16),
                     (char)(v.keyInfo.dataType >> 8), (char)v.keyInfo.dataType, 0 };
    if (strcmp(type, "sp78") == 0) {
        int8_t hi = (int8_t)v.bytes[0];
        uint8_t lo = (uint8_t)v.bytes[1];
        printf("%.3f\n", (double)hi + (double)lo / 256.0);
    } else if (strcmp(type, "fpe2") == 0) {
        uint16_t raw = ((uint16_t)(uint8_t)v.bytes[0] << 8) | (uint8_t)v.bytes[1];
        printf("%.3f\n", (double)raw / 4.0);
    } else {
        printf("%.3f\n", (double)(uint8_t)v.bytes[0] + (double)(uint8_t)v.bytes[1] / 256.0);
    }
    return 0;
}
