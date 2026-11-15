#!/bin/bash
set -e
cd "$(dirname "$0")"
IASL=${IASL:-iasl}
"$IASL" -p SSDT-FANEC.aml SSDT-FANEC.dsl
echo "built: ssdt/SSDT-FANEC.aml"
