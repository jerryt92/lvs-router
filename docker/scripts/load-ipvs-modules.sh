#!/bin/sh
set -eu

MODULES="${IPVS_MODULES:-ip_vs ip_vs_rr ip_vs_wrr ip_vs_sh}"

for module in $MODULES; do
  modprobe "$module"
done
