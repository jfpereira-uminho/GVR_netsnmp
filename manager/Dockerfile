FROM docker.io/library/alpine:3.20

# net-snmp-tools -> snmpget, snmpgetnext, snmpbulkget, snmpwalk, snmpset,
#                   snmptable, snmptranslate, snmptrap, snmpinform
# net-snmp       -> snmptrapd (notification receiver)
# util-linux-misc-> nsenter (used by lab.sh to plug the veth)
RUN apk add --no-cache net-snmp net-snmp-tools iproute2 tcpdump util-linux-misc

COPY mibs/                   /usr/share/snmp/mibs/
COPY manager/snmptrapd.conf  /etc/snmp/snmptrapd.conf
COPY manager/entrypoint.sh   /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 162/udp
ENTRYPOINT ["/entrypoint.sh"]
