FROM docker.io/library/alpine:3.20

# net-snmp       -> snmpd (agent) and snmptrapd
# net-snmp-tools -> snmpget, snmpwalk, snmptrap, ... (handy for local tests)
RUN apk add --no-cache net-snmp net-snmp-tools iproute2 tcpdump

COPY mibs/              /usr/share/snmp/mibs/
COPY agent/snmpd.conf   /etc/snmp/snmpd.conf
COPY agent/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 161/udp
ENTRYPOINT ["/entrypoint.sh"]
