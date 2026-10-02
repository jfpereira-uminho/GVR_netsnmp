#!/bin/sh
# Wait for the veth end (eth0) to be plugged in by lab.sh before starting
# snmpd, so the coldStart trap actually reaches the manager.
i=0
while ! ip -4 addr show dev eth0 2>/dev/null | grep -q 'inet '; do
    [ "$i" -eq 0 ] && echo "[agent] waiting for eth0 (run: ./lab.sh up) ..."
    i=$((i + 1))
    [ "$i" -ge 120 ] && { echo "[agent] eth0 not found, starting anyway"; break; }
    sleep 1
done
echo "[agent] starting snmpd"
# -f foreground, -Lo log to stdout, -C ignore default config files, -c our file
exec snmpd -f -Lo -C -c /etc/snmp/snmpd.conf
