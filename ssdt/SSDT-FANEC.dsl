DefinitionBlock ("", "SSDT", 2, "DSH", "FANEC", 0x00000001)
{
    External (_SB_.PC00.LPCB.ECDV, DeviceObj)
    External (_SB_.PC00.LPCB.ECDV.ECR1, MethodObj)

    Scope (\_SB)
    {
        Device (DSHF)
        {
            Name (_HID, "DSHF0001")
            Name (_UID, Zero)

            Method (RDEC, 1, Serialized)
            {
                Return (\_SB.PC00.LPCB.ECDV.ECR1 (Arg0))
            }
        }
    }
}
