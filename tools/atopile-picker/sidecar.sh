#!/usr/bin/env bash
# Sourced by the atopile build actions to run the local picker as a sidecar:
# atopile 0.15.x needs a components API for EVERY pick, so a self-contained build
# runs our local picker (tools/atopile-picker/server.py) on a free port and
# points atopile at it via ATO_SERVICES_COMPONENTS_URL. Footprints still come
# from EasyEDA unless cached under elec/src/parts (committed).
#
# Being *sourced*, this sets ATO_SERVICES_COMPONENTS_URL and $_ATO_PICKER_PID in
# the caller's shell; the caller kills that PID when the build finishes.
#
# Usage:  source sidecar.sh <path/to/server.py>

_ato_picker_server="$1"
_ato_picker_port="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"

python3 "$_ato_picker_server" "$_ato_picker_port" >/dev/null 2>&1 &
_ATO_PICKER_PID=$!
export ATO_SERVICES_COMPONENTS_URL="http://127.0.0.1:${_ato_picker_port}"

# Wait for it to accept connections (it's a tiny stdlib server; comes up fast).
python3 - "$_ato_picker_port" <<'PY'
import socket, sys, time
port = int(sys.argv[1])
for _ in range(60):
    try:
        socket.create_connection(("127.0.0.1", port), 0.3).close()
        sys.exit(0)
    except OSError:
        time.sleep(0.1)
sys.exit("local picker did not come up")
PY
