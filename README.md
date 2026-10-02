# GVR — First Contact with SNMP and MIBs (Net-SNMP)

In this lab you deploy an **SNMP agent** and an **SNMP manager** in two
containers. Each container has its own network namespace, and a **veth pair**
connects them like a virtual crossover cable. Then you use the Net-SNMP tools
to learn two things:

1. How MIB objects are named: the **OID tree**, scalars and tables.
2. What the **SNMP protocol operations (PDUs)** do, and what they look like
   on the wire.

```
  +-----------------------------+              +-----------------------------+
  | container: manager          |              | container: agent            |
  | net namespace #2            |   veth pair  | net namespace #1            |
  |                             |              |                             |
  | eth0 10.0.0.2/30  <---------+--------------+--------->  eth0 10.0.0.1/30 |
  |                             |              |                             |
  | snmptrapd  (listens udp/162)|  <-- traps --|  snmpd  (listens udp/161)   |
  | snmpget, snmpwalk, snmpset, |  -- requests>|                             |
  | snmpbulkget, snmptable, ... |              |  MIBs: SNMPv2, IF, IP, HOST |
  |                             |              |  RESOURCES, ... GVR-LAB-MIB |
  +-----------------------------+              +-----------------------------+
```

---

## 0. Requirements

* **Linux with Docker Engine** (recommended). Your user should be in the
  `docker` group, or run the commands with `sudo`.
* Docker Desktop (macOS/Windows) should also work, because the veth is
  created *inside* Docker's VM by a helper container. This setup is tested
  on Linux only.
* Podman with `podman-docker` also works, rootless included:
  `DOCKER=podman ./lab.sh ...` or just `./lab.sh ...`.
* Internet access for the first build (it pulls `alpine:3.20` and the
  `net-snmp` packages).

## 1. Repository layout

```
.
├── lab.sh                    # build / up / down / status / shell / logs
├── mibs/
│   └── GVR-LAB-MIB.txt       # a small private MIB written for this lab
├── agent/
│   ├── Dockerfile            # alpine + net-snmp (snmpd)
│   ├── snmpd.conf            # agent configuration: communities, v3 user, traps, ...
│   └── entrypoint.sh         # waits for eth0, then starts snmpd
└── manager/
    ├── Dockerfile            # alpine + net-snmp-tools + snmptrapd
    ├── snmptrapd.conf        # which notifications are accepted
    └── entrypoint.sh         # starts snmptrapd in the foreground
```

Read `agent/snmpd.conf` before you start. Every line is commented, and
most of the exercises depend on something configured there.

## 2. Build and deploy

```bash
./lab.sh build      # build images gvr-snmp-agent and gvr-snmp-manager
./lab.sh up         # start both containers, plug the veth, wait for snmpd
./lab.sh status     # show the interfaces in each container
```

Open a shell in the manager. **Run all the exercises from here unless an
exercise says otherwise.**

```bash
docker exec -it manager sh        # or: ./lab.sh shell manager
snmpwalk -v2c -c public agent system
```

In a second terminal, watch the notifications that reach the manager:

```bash
docker logs -f manager            # or: ./lab.sh logs manager
```

The `coldStart` trap that `snmpd` sent when it started should already be
there.

When you are done, tear everything down. The veth disappears with the
namespaces:

```bash
./lab.sh down
```

### 2.1 What `lab.sh up` actually does

No Docker network is used. Each container starts with `--network none`,
which gives it a **new, empty network namespace** that contains only `lo`.
The script then wires the two namespaces together by hand. On a Linux host,
the equivalent commands are:

```bash
docker run -d --name manager --hostname manager --network none \
       --cap-add NET_ADMIN --cap-add NET_RAW gvr-snmp-manager
docker run -d --name agent   --hostname agent   --network none \
       --cap-add NET_ADMIN --cap-add NET_RAW gvr-snmp-agent

# Every container is a process. Its network namespace is /proc/<pid>/ns/net
PA=$(docker inspect -f '{{.State.Pid}}' agent)
PM=$(docker inspect -f '{{.State.Pid}}' manager)
sudo readlink /proc/$PA/ns/net /proc/$PM/ns/net     # two different namespaces

# Create the veth pair inside the agent's namespace and move one end
# straight into the manager's namespace
sudo nsenter -t $PA -n ip link add eth0 type veth peer name eth0 netns $PM

sudo nsenter -t $PA -n ip addr add 10.0.0.1/30 dev eth0
sudo nsenter -t $PA -n ip link set eth0 up
sudo nsenter -t $PM -n ip addr add 10.0.0.2/30 dev eth0
sudo nsenter -t $PM -n ip link set eth0 up
```

`lab.sh` runs these same `nsenter`/`ip` commands from a short-lived
`--privileged --pid host` container. That way it needs no `sudo` and no
`iproute2` on the host.

**Check your understanding:**

```bash
docker exec agent ip -d link show eth0     # look for "veth" and "link-netnsid"
docker exec manager ping -c 3 agent
```

* Q2.1 — Why does `agent/entrypoint.sh` wait for `eth0` before starting
  `snmpd`? What would you lose if it didn't wait? (Hint: `trap2sink`.)
* Q2.2 — Why does `lab.sh` start the manager *before* the agent?
* Q2.3 — How many interfaces does the agent have? Keep the answer for §3.4.

---

## 3. MIBs and the OID tree

### 3.1 Every managed object has an OID

SNMP does not move names over the network. It moves **Object Identifiers
(OIDs)**: paths in a global tree where every node is a number. A **MIB**
is a text file (written in SMIv2, a subset of ASN.1) that gives those
numbers names, types and meaning.

```
(root)
 └─ iso(1)
     └─ org(3)
         └─ dod(6)
             └─ internet(1)                         1.3.6.1
                 ├─ mgmt(2)
                 │   └─ mib-2(1)                    1.3.6.1.2.1        standard MIBs (IETF)
                 │       ├─ system(1)               1.3.6.1.2.1.1      SNMPv2-MIB
                 │       │   ├─ sysDescr(1)
                 │       │   ├─ sysObjectID(2)
                 │       │   ├─ sysUpTime(3)
                 │       │   ├─ sysContact(4)
                 │       │   ├─ sysName(5)
                 │       │   └─ sysLocation(6)
                 │       ├─ interfaces(2)           1.3.6.1.2.1.2      IF-MIB
                 │       │   └─ ifTable(2)
                 │       │       └─ ifEntry(1)
                 │       │           ├─ ifIndex(1)
                 │       │           ├─ ifDescr(2)
                 │       │           ├─ ...
                 │       │           └─ ifInOctets(10)
                 │       ├─ ip(4)                   IP-MIB
                 │       └─ host(25)                HOST-RESOURCES-MIB
                 ├─ private(4)
                 │   └─ enterprises(1)              1.3.6.1.4.1        vendor MIBs
                 │       ├─ cisco(9)
                 │       ├─ netSnmp(8072)
                 │       └─ gvrLab(99999)           <- our lab MIB
                 └─ snmpV2(6)                       SNMP's own MIBs (engine, USM, VACM, ...)
```

Use `snmptranslate` to move between names and numbers. It works offline:
it only reads MIB files and never contacts an agent.

```sh
snmptranslate -On SNMPv2-MIB::sysName.0          # name -> number
#   .1.3.6.1.2.1.1.5.0
snmptranslate -Of SNMPv2-MIB::sysName.0          # full path of names
#   .iso.org.dod.internet.mgmt.mib-2.system.sysName.0
snmptranslate .1.3.6.1.2.1.2.2.1.10.2            # number -> name
#   IF-MIB::ifInOctets.2
snmptranslate -Tp SNMPv2-MIB::system             # draw a subtree
snmptranslate -Td IF-MIB::ifOperStatus           # full MIB definition
```

### 3.2 Object vs. instance: scalars end in `.0`

An `OBJECT-TYPE` in a MIB defines a **type of object**. To read a value
you must name an **instance** of it:

* **Scalar** objects have exactly one instance, with the suffix **`.0`**.
  Example: `sysName.0` = `1.3.6.1.2.1.1.5.0`.
* **Columnar** objects (inside a table) have one instance per row. The
  suffix is the **row index**.
  Example: `ifDescr.2` = `1.3.6.1.2.1.2.2.1.2.2`.

```
 1.3.6.1.2.1.2.2 . 1 . 2 . 2
 \_____________/   |   |   \__ index      -> row where ifIndex = 2  (eth0)
     ifTable       |   \______ column     -> ifDescr (2)
                   \__________ ifEntry    -> the "row" type, always 1
```

```sh
snmpget -v2c -c public agent sysName.0        # works
snmpget -v2c -c public agent sysName          # fails: that is the object, not an instance
snmpget -v2c -c public agent ifDescr.2
snmptable -v2c -c public -Cb agent IF-MIB::ifTable
```

### 3.3 Reading a MIB: `mibs/GVR-LAB-MIB.txt`

Open `mibs/GVR-LAB-MIB.txt`. It is small on purpose. Find these parts:

| Construct | What it does |
|---|---|
| `IMPORTS ... FROM SNMPv2-SMI` | Reuses definitions (`enterprises`, `Integer32`, ...) from other MIBs |
| `MODULE-IDENTITY ::= { enterprises 99999 }` | Puts the whole module in the tree: `1.3.6.1.4.1.99999` |
| `OBJECT IDENTIFIER ::= { gvrLab 1 }` | A plain branch node with no value. It only organises the tree |
| `OBJECT-TYPE` | A managed object: `SYNTAX` (type), `MAX-ACCESS`, `STATUS`, `DESCRIPTION` |
| `SEQUENCE OF` / `INDEX { ... }` | A conceptual table and how its rows are numbered |
| `NOTIFICATION-TYPE` | A trap/inform definition and the objects (`OBJECTS`) it carries |

The agent serves this MIB's objects. First look at them **without** the
MIB loaded on the manager:

```sh
snmpwalk -v2c -c public agent .1.3.6.1.4.1.99999
#   SNMPv2-SMI::enterprises.99999.1.1.1.0 = STRING: "GVR SNMP lab agent"
#   ...
#   SNMPv2-SMI::enterprises.99999.1.2.1.4.2 = INTEGER: 2
```

Now load it with `-m +GVR-LAB-MIB`. The `+` means "in addition to the
default MIBs".

```sh
snmpwalk  -v2c -c public -m +GVR-LAB-MIB agent GVR-LAB-MIB::gvrLab
#   GVR-LAB-MIB::gvrLabName.0 = STRING: GVR SNMP lab agent
#   ...
#   GVR-LAB-MIB::gvrLabRoomStatus.2 = INTEGER: warning(2)
snmptable -v2c -c public -m +GVR-LAB-MIB agent GVR-LAB-MIB::gvrLabRoomTable
snmptranslate -m +GVR-LAB-MIB -Tp GVR-LAB-MIB::gvrLab
```

To avoid typing `-m` every time: `export MIBS=+GVR-LAB-MIB`.

> **Key idea:** the agent sends **exactly the same bytes** in both cases.
> The MIB exists only on the manager side. It turns numbers into names,
> `2` into `warning(2)`, and `287` into a value with units. A manager
> without the vendor's MIB can still talk to the device, but it sees bare
> numbers.

* Q3.1 — What is the full numeric OID of `gvrLabRoomTemp` for the
  "Server room"? Work it out on paper from the MIB, then check it with
  `snmptranslate -On`.
* Q3.2 — `gvrLabRoomIndex` is `not-accessible`. Try
  `snmpget ... GVR-LAB-MIB::gvrLabRoomIndex.1`. Why does the MIB not need
  it to be readable? (Look at the instance OIDs from the walk.)
* Q3.3 — `snmpget ... sysUpTime.0` replies with the name
  `DISMAN-EVENT-MIB::sysUpTimeInstance`. Use `snmptranslate -On` on both
  names. What does this tell you about OIDs vs. names?
* Q3.4 — MIB comments start with `--`, and a **second `--` on the same
  line ends the comment**. Why would a line like
  `-- +-- gvrLab(99999)` break the MIB parser?

### 3.4 Table indexes are not always integers

The agent exposes the output of a command through `NET-SNMP-EXTEND-MIB`
(see `extend hello` in `snmpd.conf`). That table is indexed by a
**string**:

```sh
snmpwalk -v2c -c public     agent NET-SNMP-EXTEND-MIB::nsExtendOutput1Line
#   NET-SNMP-EXTEND-MIB::nsExtendOutput1Line."hello" = STRING: Hello from the GVR SNMP agent
snmpwalk -v2c -c public -On agent NET-SNMP-EXTEND-MIB::nsExtendOutput1Line
#   .1.3.6.1.4.1.8072.1.3.2.3.1.1.5.104.101.108.108.111 = STRING: ...
```

* Q3.5 — Decode `.5.104.101.108.108.111`. What is the `5`? What are the
  other numbers? (`man ascii`)
* Q3.6 — Walk `IP-MIB::ipAddressTable` with and without `-On`. What
  forms the index of that table?

---

## 4. SNMP protocol operations (PDUs)

| PDU | Sent by | Purpose | Tool |
|---|---|---|---|
| `GetRequest` | manager | Read the given instance(s) | `snmpget` |
| `GetNextRequest` | manager | Read the **next** instance in OID order | `snmpgetnext`, `snmpwalk` |
| `GetBulkRequest` | manager (v2c/v3) | Many GETNEXTs in one request | `snmpbulkget`, `snmpbulkwalk` |
| `SetRequest` | manager | Write instance(s) | `snmpset` |
| `Response` | agent / trap receiver | Answer to any of the above, and to `InformRequest` | — |
| `SNMPv2-Trap` | agent | Unacknowledged notification (udp/162) | `snmptrap` |
| `InformRequest` | agent | **Acknowledged** notification | `snmpinform` |
| `Report` | SNMP engine (v3) | Engine discovery and errors | — |

Keep a capture running in another terminal throughout this section, so
you see every PDU as it goes over the veth:

```bash
docker exec -it manager tcpdump -ni eth0 -vv udp
```

You can ignore the `bad udp cksum` messages. The veth offloads checksums,
so tcpdump sees packets before the checksum is filled in.

### 4.1 GET

```sh
snmpget -v2c -c public agent sysDescr.0 sysUpTime.0 sysName.0   # 3 varbinds, 1 PDU
```

Error handling. Compare v2c with v1:

```sh
snmpget -v2c -c public agent sysDescr.1               # noSuchInstance
snmpget -v2c -c public agent .1.3.6.1.4.1.12345.1.0   # noSuchObject
snmpget -v1  -c public agent sysDescr.1               # error-status noSuchName
```

* Q4.1 — In tcpdump, how many packets did the 3-varbind `snmpget`
  generate? What field links the response to the request?
* Q4.2 — v1 reports the error in the PDU header (`error-status`). Where
  does v2c report it? Run `snmpget -v1 -c public agent sysDescr.1 sysName.0`
  and `snmpget -v2c -c public agent sysDescr.1 sysName.0` with tcpdump
  open. Why does the v1 version produce **4** packets? (The Net-SNMP
  client re-sends the request without the failing varbind; `-Cf` turns
  that off.) Why is the v2c behaviour better?

### 4.2 GETNEXT and the lexicographic order

`GetNext(X)` returns the first instance whose OID is **strictly greater**
than `X`. `X` does not have to exist.

```sh
snmpgetnext -v2c -c public agent system          # -> sysDescr.0
snmpgetnext -v2c -c public agent sysDescr.0      # -> sysObjectID.0
snmpgetnext -v2c -c public agent ifDescr.2       # -> ifType.1  (!)
```

`snmpwalk` is **not a PDU**. It is a loop: send GETNEXT, take the
returned OID, send GETNEXT again, and stop when the returned OID leaves
the subtree.

* Q4.3 — Walk `GVR-LAB-MIB::gvrLabInfo` by hand with
  `snmpgetnext -m +GVR-LAB-MIB`, feeding each answer into the next
  request. How many requests did you need? How do you know when to stop?
  Then count the lines of `snmpwalk -v2c -c public agent system`. How many
  GETNEXTs would that walk take?
* Q4.4 — Why does `ifDescr.2` → `ifType.1`? Draw the table and number
  the cells in the order GETNEXT visits them. Does a walk go row by row
  or column by column?

### 4.3 GETBULK

A `GetBulkRequest` has two extra fields:

* **non-repeaters (N)**: the first N varbinds get a single GETNEXT each.
* **max-repetitions (M)**: each remaining varbind gets up to M GETNEXTs.

```sh
snmpbulkget -v2c -c public -Cn0 -Cr5 agent system
snmpbulkget -v2c -c public -Cn1 -Cr2 agent sysUpTime ifDescr ifOperStatus
```

* Q4.5 — Explain each line of the second output with N=1, M=2. How many
  varbinds should the response have?
* Q4.6 — Run `snmpwalk -v2c ...` and then `snmpbulkwalk -v2c ...` on
  `IF-MIB::interfaces`, and count the packets in tcpdump. Both use v2c,
  so why is the difference so large? Which PDU does each tool use?
* Q4.7 — Run `snmpbulkget -v2c -c public -Cr50 agent ifInOctets`. Why do
  you get objects that are not `ifInOctets`? What does this tell you
  about the agent's knowledge of the "end of a table"?

### 4.4 SET

The agent defines two communities (see `snmpd.conf`): `public`
(read-only) and `private` (read-write). `snmpset` needs a **type** for
each value: `i` integer, `u` unsigned, `s` string, `x` hex, `o` OID,
`a` IP address, `t` timeticks.

```sh
snmpset -v2c -c private agent sysContact.0 s "student@uminho.pt" sysLocation.0 s "Braga"
snmpget -v2c -c public  agent sysContact.0 sysLocation.0

snmpset -v2c -c private -m +GVR-LAB-MIB agent GVR-LAB-MIB::gvrLabStudent.0 s "your name"
snmpget -v2c -c public  -m +GVR-LAB-MIB agent GVR-LAB-MIB::gvrLabStudent.0
```

Now break it on purpose and read the error each time:

```sh
snmpset -v2c -c public  agent sysContact.0 s x                               # noAccess
snmpset -v2c -c private -m +GVR-LAB-MIB agent GVR-LAB-MIB::gvrLabName.0 s x  # notWritable
snmpset -v2c -c private agent sysContact.0 i 5                               # caught by the CLIENT (MIB says string)
snmpset -v2c -c private agent .1.3.6.1.4.1.99999.1.1.3.0 i 5                 # wrongType, from the AGENT
```

* Q4.8 — In the third command no packet is sent. Why? What changes in
  the fourth command?
* Q4.9 — In `snmpd.conf`, `sysContact`/`sysLocation` are *not* set. What
  happens to SET on those objects if you add `sysContact foo` to the
  file? (Try it: edit the file, then `./lab.sh build && ./lab.sh restart`.)
* Q4.10 — Run `./lab.sh restart` and read `sysContact.0` again. What
  happened to your SET? What does that tell you about where an agent
  stores its configuration?

### 4.5 Notifications: TRAP and INFORM

Keep `docker logs -f manager` open.

**Traps the agent sends automatically** (see `trap2sink` and
`authtrapenable` in `snmpd.conf`):

```sh
# Ask with a wrong community. The request goes unanswered (Timeout),
# but the agent reports an authenticationFailure trap to the manager.
snmpget -v2c -c wrong -t 1 -r 0 agent sysName.0
```

**Sending a notification from the agent by hand**. Open a shell in the
*agent* (`docker exec -it agent sh`):

```sh
# '' = let the tool fill in sysUpTime; then the notification OID; then the varbinds
snmptrap  -v2c -c public manager '' GVR-LAB-MIB::gvrLabTempAlarm \
          GVR-LAB-MIB::gvrLabRoomName.2 s "Server room" \
          GVR-LAB-MIB::gvrLabRoomTemp.2 i 315

snmpinform -v2c -c public manager '' GVR-LAB-MIB::gvrLabTempAlarm \
          GVR-LAB-MIB::gvrLabRoomTemp.2 i 320

# The manager only accepts community "public"
snmpinform -v2c -c wrong -t 1 -r 2 manager '' GVR-LAB-MIB::gvrLabTempAlarm
snmptrap   -v2c -c wrong          manager '' GVR-LAB-MIB::gvrLabTempAlarm
```

* Q4.11 — Look at the first two varbinds of any trap in the log
  (`sysUpTime.0` and `snmpTrapOID.0`). Why does every v2 notification
  start with them?
* Q4.12 — With the wrong community, `snmpinform` fails (Timeout) but
  `snmptrap` "succeeds". Neither reaches the log. Explain the difference
  using tcpdump. When would you choose INFORM over TRAP?
* Q4.13 — The manager decodes `gvrLabTempAlarm` by name because
  `snmptrapd` is started with `-m +GVR-LAB-MIB` (see
  `manager/entrypoint.sh`). What would the log show without it?

---

## 5. Security: SNMPv2c vs SNMPv3

With v2c, the community is the only credential, and it travels in clear
text. Start a capture that prints packet payloads as ASCII:

```bash
docker exec -it manager tcpdump -ni eth0 -A udp port 161     # look for "private"
```

and in the manager shell:

```sh
snmpget -v2c -c private agent sysName.0
```

The agent also has a v3 user (`createUser` in `snmpd.conf`) with
authentication (SHA) and encryption (AES):

```sh
snmpget -v3 -l authPriv -u gvrUser -a SHA -A gvrAuthPass -x AES -X gvrPrivPass agent sysName.0
snmpget -v3 -l authPriv -u gvrUser -a SHA -A wrongPassword -x AES -X gvrPrivPass agent sysName.0
```

* Q5.1 — In tcpdump, a single v3 `snmpget` produces **4** packets, not 2.
  What is the first exchange, and what does the agent return in the
  `Report` PDU? (Hint: `snmpEngineID`.)
* Q5.2 — Can you read the requested OID or the returned value in the v3
  capture? What *can* you still see?
* Q5.3 — Try `-l authNoPriv` and `-l noAuthNoPriv`. Which ones does the
  agent accept for `gvrUser`, and why? (Look at the `rwuser` line.)

---

## 6. Challenge exercises

1. **Counters.** Read `IF-MIB::ifInOctets.2` and `ifOutOctets.2` on the
   agent. Run `ping -c 100 -i 0.2 -s 1000 agent` from the manager and
   read the counters again. Do the numbers match what you expect? Why does
   `ifSpeed.2` show `4294967295`, and which object should you read
   instead? (`snmptranslate -Td IF-MIB::ifHighSpeed`)
2. **Link state.** In the manager, run `ip link set eth0 down`. In the
   agent, run `snmpget -v2c -c public localhost ifOperStatus.2
   ifLastChange.2`. Bring the link back up. Why do you have to query from
   the agent itself? (The agent caches interface tables for a few
   seconds, so wait a moment before you read the new state.)
3. **Extend the MIB.** Add a fourth room to the agent (`override` lines
   in `snmpd.conf`) and a new read-only scalar `gvrLabRoomCount` to
   `GVR-LAB-MIB.txt`. Pick its OID yourself, implement it, rebuild, and
   check it with `snmptranslate` and `snmpget`.
4. **Access control.** Change `snmpd.conf` so that `public` can only see
   the `system` group (`view` / `rocommunity ... -V`). Verify with
   `snmpwalk ... mib-2`.

---

## 7. Troubleshooting

| Symptom | Fix |
|---|---|
| `container 'agent' already exists` | `./lab.sh down` and try again |
| `images not found` | `./lab.sh build` |
| `Timeout: No Response from agent` | Check the community/version, then `./lab.sh status` (do both eth0 have an IP?) and `docker logs agent` |
| `Unknown Object Identifier` | Load the MIB (`-m +GVR-LAB-MIB`) or use the numeric OID |
| `Bad operator` / parse errors when loading a MIB | Syntax error in the MIB file, usually a `--` inside a comment |
| `Emulate Docker CLI using podman` messages | Harmless (podman-docker). `sudo touch /etc/containers/nodocker` silences them |
| Docker Desktop: `lab.sh up` fails in `nsenter` | Use a Linux VM / WSL2 with Docker Engine |

## 8. Net-SNMP option cheat sheet

| Option | Meaning |
|---|---|
| `-v 1 / 2c / 3` | SNMP version |
| `-c <community>` | Community (v1/v2c) |
| `-l noAuthNoPriv / authNoPriv / authPriv` | v3 security level |
| `-u -a -A -x -X` | v3 user, auth protocol, auth pass, priv protocol, priv pass |
| `-m +MIB` / `-m ALL` | Load an extra MIB / all MIBs |
| `-On` / `-Of` / `-OS` | Output OIDs numeric / full names / `MIB::name` |
| `-Cn N -Cr M` | GETBULK non-repeaters / max-repetitions |
| `-t <sec> -r <n>` | Timeout and retries |
| `-d` | Hex dump of every packet sent and received |

Manual pages: `snmpcmd(1)`, `snmpget(1)`, `snmpwalk(1)`, `snmpset(1)`,
`snmptranslate(1)`, `snmptrap(1)`, `snmpd.conf(5)`, `snmptrapd.conf(5)`.
RFCs: 3416 (PDUs), 2578 (SMIv2), 3418 (SNMPv2-MIB), 2863 (IF-MIB),
3414 (USM).
