#!/bin/sh
# The manager container runs snmptrapd in the foreground, so received
# notifications show up in `docker logs -f manager` and in
# /var/log/snmptrapd.log. Students use `docker exec -it manager sh`
# to run the snmp* commands.
echo "[manager] starting snmptrapd (traps logged here and in /var/log/snmptrapd.log)"
# -f foreground, -Lo log to stdout, -Lf also log to file, -m +GVR-LAB-MIB
# load our MIB so its notifications are decoded, -C ignore default
# config files, -c our file
exec snmptrapd -f -Lo -Lf /var/log/snmptrapd.log -m +GVR-LAB-MIB \
    -C -c /etc/snmp/snmptrapd.conf
