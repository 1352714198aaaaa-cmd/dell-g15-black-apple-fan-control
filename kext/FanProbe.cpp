#include <IOKit/IOService.h>
#include <IOKit/IOLib.h>
#include <IOKit/acpi/IOACPIPlatformDevice.h>
#include <IOKit/acpi/IOACPITypes.h>
#include <sys/sysctl.h>
#include <sys/errno.h>
#include <mach/kmod.h>

#define super IOService

static IOACPIPlatformDevice *gDev = NULL;
static IOACPIPlatformDevice *gEcDev = NULL;
static int gLastMode = -1;
static int gLastRet = -1;
static int gLastVal = -1;

static int wmax(UInt32 a1, UInt32 b0, UInt32 b1, UInt32 b2, UInt32 *out)
{
    if (!gDev) return -1;
    UInt8 buf[4] = { (UInt8)b0, (UInt8)b1, (UInt8)b2, 0 };
    OSData   *data = OSData::withBytes(buf, sizeof(buf));
    OSNumber *n0 = OSNumber::withNumber((unsigned long long)0, 32);
    OSNumber *n1 = OSNumber::withNumber((unsigned long long)a1, 32);
    if (!data || !n0 || !n1) { if (data) data->release(); if (n0) n0->release(); if (n1) n1->release(); return -2; }
    OSObject *params[3] = { n0, n1, data };
    OSObject *res = NULL;
    IOReturn r = gDev->evaluateObject("WMAX", &res, params, 3, 0);
    int rc = (int)r;
    if (r == 0) {
        OSNumber *n = OSDynamicCast(OSNumber, res);
        if (n && out) *out = (UInt32)n->unsigned64BitValue();
        else rc = -3;
    }
    if (res) res->release();
    data->release(); n0->release(); n1->release();
    return rc;
}

static int fan_sysctl_mode SYSCTL_HANDLER_ARGS
{
    int v = 0;
    int err = sysctl_handle_int(oidp, &v, 0, req);
    if (err || req->newptr == 0) return err;
    UInt32 out = 0;
    gLastRet = wmax(0x15, 1, (UInt32)v, 0, &out);
    gLastVal = (int)out;
    gLastMode = v;
    return 0;
}

static int fan_sysctl_duty SYSCTL_HANDLER_ARGS
{
    int v = 0;
    int err = sysctl_handle_int(oidp, &v, 0, req);
    if (err || req->newptr == 0) return err;
    UInt32 out = 0;
    gLastRet = wmax(0x15, 2, (UInt32)((v >> 8) & 0xFF), (UInt32)(v & 0xFF), &out);
    gLastVal = (int)out;
    return 0;
}

static int fan_sysctl_ecread SYSCTL_HANDLER_ARGS
{
    int v = 0;
    int err = sysctl_handle_int(oidp, &v, 0, req);
    if (err || req->newptr == 0) return err;
    if (!gEcDev) { gLastRet = -4; return EIO; }
    OSNumber *n = OSNumber::withNumber((unsigned long long)(v & 0xFF), 32);
    if (!n) return ENOMEM;
    OSObject *params[1] = { n };
    OSObject *res = NULL;
    IOReturn r = gEcDev->evaluateObject("RDEC", &res, params, 1, 0);
    gLastRet = (int)r;
    if (r == 0) {
        OSNumber *rn = OSDynamicCast(OSNumber, res);
        gLastVal = rn ? (int)rn->unsigned64BitValue() : -1;
    }
    if (res) res->release();
    n->release();
    return 0;
}

static int fan_sysctl_ec50 SYSCTL_HANDLER_ARGS
{
    int v = 0;
    int err = sysctl_handle_int(oidp, &v, 0, req);
    if (err || req->newptr == 0) return err;
    UInt32 out = 0;
    gLastRet = wmax(0x25, 2, 0, 0, &out);
    gLastVal = (int)out;
    return 0;
}

SYSCTL_NODE(_kern, OID_AUTO, fanprobe, CTLFLAG_RW | CTLFLAG_KERN, 0, "FanProbe");
SYSCTL_PROC(_kern_fanprobe, OID_AUTO, mode, CTLTYPE_INT | CTLFLAG_RW | CTLFLAG_ANYBODY, 0, 0, fan_sysctl_mode, "I", "thermal mode (0xA0..0xAB)");
SYSCTL_PROC(_kern_fanprobe, OID_AUTO, duty, CTLTYPE_INT | CTLFLAG_RW | CTLFLAG_ANYBODY, 0, 0, fan_sysctl_duty, "I", "fan duty: fanId<<8|duty");
SYSCTL_PROC(_kern_fanprobe, OID_AUTO, ecread, CTLTYPE_INT | CTLFLAG_RW | CTLFLAG_ANYBODY, 0, 0, fan_sysctl_ecread, "I", "read EC register (write reg, read lastval)");
SYSCTL_PROC(_kern_fanprobe, OID_AUTO, ec50, CTLTYPE_INT | CTLFLAG_RW | CTLFLAG_ANYBODY, 0, 0, fan_sysctl_ec50, "I", "read EC 0x50");
SYSCTL_INT(_kern_fanprobe, OID_AUTO, lastret, CTLFLAG_RD, &gLastRet, 0, "last WMAX return");
SYSCTL_INT(_kern_fanprobe, OID_AUTO, lastval, CTLFLAG_RD, &gLastVal, 0, "last WMAX value");
SYSCTL_INT(_kern_fanprobe, OID_AUTO, lastmode, CTLFLAG_RD, &gLastMode, 0, "last mode set");

class FanProbe : public IOService {
    OSDeclareDefaultStructors(FanProbe)
public:
    virtual bool start(IOService *provider) APPLE_KEXT_OVERRIDE;
    virtual void stop(IOService *provider) APPLE_KEXT_OVERRIDE;
};

OSDefineMetaClassAndStructors(FanProbe, IOService)

extern "C" {
    static kern_return_t FanProbeModuleStart(kmod_info_t *ki, void *data) { (void)ki; (void)data; return KERN_SUCCESS; }
    static kern_return_t FanProbeModuleStop(kmod_info_t *ki, void *data) { (void)ki; (void)data; return KERN_SUCCESS; }
    KMOD_EXPLICIT_DECL(com.dsh.fanprobe, "0.2", FanProbeModuleStart, FanProbeModuleStop)
}

bool FanProbe::start(IOService *provider) {
    if (!super::start(provider)) { setProperty("Stage", "super-start-failed"); return false; }
    setProperty("Stage", "super-start-ok");

    IORegistryEntry *e = IORegistryEntry::fromPath("IOACPIPlane:/_SB/AMWW", gIOACPIPlane);
    if (!e) e = IORegistryEntry::fromPath("/_SB/AMWW", gIOACPIPlane);
    gDev = OSDynamicCast(IOACPIPlatformDevice, e);
    setProperty("DevicePath", gDev ? "found" : "not-found");
    if (!gDev) return false;

    IORegistryEntry *e2 = IORegistryEntry::fromPath("IOACPIPlane:/_SB/DSHF", gIOACPIPlane);
    if (!e2) e2 = IORegistryEntry::fromPath("/_SB/DSHF", gIOACPIPlane);
    gEcDev = OSDynamicCast(IOACPIPlatformDevice, e2);
    setProperty("EcDevice", gEcDev ? "found" : "not-found");

    UInt32 v = 0;
    int rc = wmax(0x21, 0, 0, 0, &v);
    setProperty("Sanity21", (UInt32)v, 32);
    setProperty("SanityRet", (UInt32)rc, 32);

    sysctl_register_oid(&sysctl__kern_fanprobe);
    sysctl_register_oid(&sysctl__kern_fanprobe_mode);
    sysctl_register_oid(&sysctl__kern_fanprobe_duty);
    sysctl_register_oid(&sysctl__kern_fanprobe_ecread);
    sysctl_register_oid(&sysctl__kern_fanprobe_ec50);
    sysctl_register_oid(&sysctl__kern_fanprobe_lastret);
    sysctl_register_oid(&sysctl__kern_fanprobe_lastval);
    sysctl_register_oid(&sysctl__kern_fanprobe_lastmode);
    setProperty("Sysctl", "registered");
    registerService();
    return true;
}

void FanProbe::stop(IOService *provider) {
    sysctl_unregister_oid(&sysctl__kern_fanprobe_lastmode);
    sysctl_unregister_oid(&sysctl__kern_fanprobe_lastval);
    sysctl_unregister_oid(&sysctl__kern_fanprobe_lastret);
    sysctl_unregister_oid(&sysctl__kern_fanprobe_ec50);
    sysctl_unregister_oid(&sysctl__kern_fanprobe_ecread);
    sysctl_unregister_oid(&sysctl__kern_fanprobe_duty);
    sysctl_unregister_oid(&sysctl__kern_fanprobe_mode);
    sysctl_unregister_oid(&sysctl__kern_fanprobe);
    gDev = NULL;
    super::stop(provider);
}
