#!/bin/bash
#####################################
# Upgrade 139: Drop the stale AES67 transmit lead from stored configs
#
# AES67Config::targetLeadMs is how far ahead of its own declared playout time
# each RTP packet goes on the wire.  It defaulted to 20ms, and 20ms was wrong:
# the lead has to be held in the receiver's playout buffer, so the ceiling is
# the smallest link offset on the network (0.25-5ms on Dante/RAVENNA), not
# something the sender picks.  A Brooklyn II has the depth to absorb 20ms;
# Ultimo-class receivers do not, and report every packet as late or missing on
# a stream whose payload, sequence, timestamps, pacing and media clock all
# measure perfect.  See issue #2848.  The default is now 3ms, verified on both.
#
# Changing that default does not reach an existing box.  fppd reads the key out
# of config/pipewire-aes67-instances.json and only falls back to the compiled
# default when it is absent, and the AES67 page GETs that whole document and
# POSTs it back verbatim on every save -- so a 20 written by the old default
# round-trips through every update forever.  It has to be removed from disk.
#
# Removing the key rather than rewriting it to 3 is deliberate: the box then
# tracks fppd's default, including the next time it moves.
#
# Only an exact 20 is touched.  Any other value was typed by someone who meant
# it -- a network of deep-buffered receivers is a legitimate reason to raise
# the lead -- and is left alone.  Idempotent, and safe on a box that never had
# AES67 configured.
#####################################

BINDIR=$(cd $(dirname $0) && pwd)
. ${BINDIR}/../../scripts/common

echo "FPP - Upgrade 139: Drop the stale AES67 transmit lead (targetLeadMs 20)"

CONFIG="${CFGDIR}/pipewire-aes67-instances.json"

if [ ! -f "${CONFIG}" ]; then
    echo "  No AES67 configuration on this system - nothing to do"
    exit 0
fi

python3 - "${CONFIG}" << 'PYEOF'
import json
import os
import sys

LEGACY_LEAD_MS = 20
path = sys.argv[1]

try:
    with open(path) as f:
        cfg = json.load(f)
except (OSError, ValueError) as e:
    # A config fppd itself could not parse is not this upgrade's to repair, and
    # failing here would stop the whole config upgrade chain.
    print(f"    Could not read {path} ({e}) - leaving it alone")
    sys.exit(0)

if not isinstance(cfg, dict) or "targetLeadMs" not in cfg:
    print("    No stored transmit lead - the box already tracks fppd's default")
    sys.exit(0)

lead = cfg["targetLeadMs"]
if lead != LEGACY_LEAD_MS:
    print(f"    Transmit lead is {lead}ms, not the old {LEGACY_LEAD_MS}ms "
          f"default - left as configured")
    sys.exit(0)

del cfg["targetLeadMs"]

# Write via a temp file in the same directory and rename, so an interrupted
# upgrade cannot leave fppd a truncated config to read on the next start.
tmp = path + ".upgrade139"
with open(tmp, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
    f.flush()
    os.fsync(f.fileno())
st = os.stat(path)
os.chmod(tmp, st.st_mode)
try:
    os.chown(tmp, st.st_uid, st.st_gid)
except OSError:
    pass
os.rename(tmp, path)

print(f"    Removed targetLeadMs {LEGACY_LEAD_MS} - AES67 will use fppd's "
      f"default lead")
PYEOF

exit 0
