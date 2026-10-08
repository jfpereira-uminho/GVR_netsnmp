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

The reference setup for this course is **Ubuntu on WSL2 with Docker
Engine installed inside Ubuntu** (`docker-ce` from `apt`). A native Linux
machine with Docker Engine behaves the same way.

* Internet access for the first build (it pulls `alpine:3.20` and the
  `net-snmp` packages).
* Other setups: Docker Desktop (Windows/macOS) runs `lab.sh` fine, but
  the host-side commands in §2.1/§2.2 need the *host shell* described in
  §2.2. Podman (`podman-docker`, rootless included) also works.

### 0.1 Pre-flight check (Ubuntu on WSL2)

Run these in your Ubuntu terminal before the class:

```bash
wsl.exe -l -v                      # your distro must show VERSION 2 (WSL1 cannot run containers)
docker info --format '{{.OperatingSystem}}'
                                   # must print "Ubuntu ...". If it prints "Docker Desktop",
                                   # the containers run in Docker Desktop's VM, not in Ubuntu
                                   # (see the host-shell note in §2.2)
docker run --rm hello-world        # the daemon is running and you can use it
```

If `docker` only works with `sudo`, add yourself to the `docker` group
(`sudo usermod -aG docker $USER`). Then, in PowerShell, run
`wsl --shutdown` and reopen Ubuntu.

Two WSL pitfalls:

* **Clone the repository inside WSL** (`cd ~ && git clone ...`), not in
  `/mnt/c/...`. Builds are much faster there, and files keep their Linux
  permissions.
* **Line endings.** If the files get Windows (CRLF) line endings, for
  example by editing them with a Windows editor or cloning with Git for
  Windows, the scripts fail with confusing errors:
  `/usr/bin/env: 'bash\r': No such file or directory` for `lab.sh`, or
  `exec /entrypoint.sh: no such file or directory` when the agent starts.
  The repository's `.gitattributes` forces LF on clone. To repair a
  broken copy: `sed -i 's/\r$//' lab.sh */entrypoint.sh` and then
  `./lab.sh build`. In VS Code, edit the files through the WSL
  extension (`code .` from Ubuntu).

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
* Q2.3 — How many interfaces does the agent have? Keep the answer for §3.2.

### 2.2 Where is the veth? Namespaces from the host's point of view

A container is a set of ordinary Linux processes, each placed in its own
**namespaces**. Each namespace type isolates one kind of resource:

| Namespace | Isolates |
|---|---|
| `net` | interfaces, IP addresses, routes, ARP table, sockets/ports |
| `pid` | process IDs |
| `mnt` | the filesystem tree |
| `uts` | hostname |
| `user` | UIDs/GIDs and *privileges* (capabilities) |
| `time` | the boot and monotonic clocks (Docker does not use it) |
| `ipc`, `cgroup` | System V IPC, the view of the cgroup tree |

What is **not** in that list is just as important: **the kernel itself**.
Every container on a machine runs on the same, single kernel.

A network interface belongs to **exactly one network namespace** at a
time. `lab.sh` creates the veth inside the agent's namespace and moves
the other end into the manager's, so **neither end is in the host's
namespace**:

```
  host network namespace          agent netns            manager netns
  ----------------------          -----------            -------------
  lo                              lo                     lo
  eth0 / wlan0 (real NICs)        eth0 (ifindex 2) <---> eth0 (ifindex 2)
  docker0 ...                      10.0.0.1/30   veth     10.0.0.2/30
  (no veth here!)
```

**1. The host does not see it:**

```bash
ip link                                   # on the host: no 10.0.0.x, no veth
```

**2. But the namespaces are there.** Every process shows its namespaces
in `/proc/<pid>/ns/`, and two processes are in the same namespace when
they show the same inode number:

```bash
PA=$(docker inspect -f '{{.State.Pid}}' agent)
PM=$(docker inspect -f '{{.State.Pid}}' manager)
readlink /proc/self/ns/net                # the host shell's netns
sudo readlink /proc/$PA/ns/net            # agent: a different number
sudo readlink /proc/$PM/ns/net            # manager: a third number
sudo ls -l /proc/$PA/ns/                  # all the agent's namespaces at once
sudo lsns -t net                          # every network namespace on the machine
ps -o pid,user,cmd -p $PA                 # snmpd, seen from the host
```

Inside the container, `snmpd` is PID 1 and runs as `root`. From the host
it has an ordinary PID, and with Docker its user really is the host's
`root`, because Docker does not use a user namespace.

**3. Look inside a namespace from the host.** `nsenter -n` enters only
the *network* namespace and runs the **host's** `ip` binary there:

```bash
sudo nsenter -t $PA -n ip -d link show eth0      # "veth", "eth0@if2", "link-netnsid"
sudo nsenter -t $PM -n ip -br addr
```

**4. Why is `ip netns list` empty?** `ip netns` only knows namespaces
that have a *name*: a bind mount in `/run/netns/`. Docker and Podman
never create one. You can name a container's namespace yourself:

```bash
sudo ip netns attach agent   $PA
sudo ip netns attach manager $PM
ip netns list
sudo ip netns exec agent ip -br addr
sudo ip -all netns exec ip -br link show eth0    # run in every named netns
sudo ip netns delete agent; sudo ip netns delete manager   # removes only the names
```

**5. Prove that the two ends belong together.** In each namespace,
`ifindex` is the interface's own number and `iflink` is its peer's
number. `@if2` in `ip link` means "my peer is ifindex 2 *in the other
namespace*", not "in this namespace":

```bash
docker exec agent   cat /sys/class/net/eth0/ifindex /sys/class/net/eth0/iflink
docker exec manager cat /sys/class/net/eth0/ifindex /sys/class/net/eth0/iflink
docker exec agent   cat /sys/class/net/eth0/address  # agent's MAC ...
docker exec manager sh -c 'ping -c1 agent >/dev/null; ip neigh'   # ... learned by the manager
```

> **`ip` vs `iplink`.** The images are Alpine Linux, whose basic commands
> come from **BusyBox**, a single small binary that implements around 300
> utilities. `ip` is the real iproute2. `iplink`, `ipaddr` and `iproute`
> are BusyBox versions. BusyBox ignores `link-netnsid` and prints a
> misleading `eth0@eth0`. Always use `ip link`.

> **No `sudo`, or Docker Desktop?** With Docker
> Desktop, the real host of the containers is Docker's VM, not your
> machine or your WSL distro. Open a **host shell** there: a throw-away
> privileged container that shares the VM's PID namespace (`--pid host`)
> and network namespace (`--network host`). This is the same trick
> `lab.sh` uses to plug the veth.
> ```bash
> PA=$(docker inspect -f '{{.State.Pid}}' agent)
> PM=$(docker inspect -f '{{.State.Pid}}' manager)
> docker run -it --rm --privileged --pid host --network host \
>        -e PA=$PA -e PM=$PM --entrypoint sh gvr-snmp-manager
> ```
> Inside it, run steps 1–4 above **without `sudo`**: `ip link`,
> `readlink /proc/$PA/ns/net` (BusyBox `readlink` takes one file per
> call), `lsns -t net`, `nsenter -t $PA -n ip -d link`. Q2.7 also works
> there: `ip link show master docker0`.

> **Rootless Podman: `podman unshare` is not enough.** Rootless Podman
> adds a **user namespace**: both containers share one user namespace
> (where the user is "root"), and each has its own network namespace
> *inside* it. `podman unshare` enters only the user namespace. You get
> privileges there, but you are still in the host's network namespace,
> so `podman unshare ip link` shows the host's interfaces. Enter both:
> ```bash
> PA=$(podman inspect -f '{{.State.Pid}}' agent)
> nsenter -t $PA -n ip link                      # Operation not permitted
> podman unshare ip link                         # user ns only -> host interfaces
> podman unshare nsenter -t $PA -n ip -d link    # user ns + net ns -> the veth
> podman unshare readlink /proc/$PA/ns/user /proc/$PA/ns/net
> ```
> `ip netns exec` does not work rootless (it cannot mount `/sys`). Use
> `nsenter` instead. With Docker (rootful) the containers use the host's
> user namespace, so this case does not arise.

* Q2.4 — Why does `ip link` on the host not show the veth at all? What
  would you have to do to make one end appear on the host?
* Q2.5 — `nsenter -t $PA -n ip link` shows the agent's interfaces, but
  `nsenter -t $PA -n cat /etc/hostname` prints the **host's** hostname.
  Why? Which `nsenter` flag would change that?
* Q2.6 — After `sudo ip netns delete agent`, is the agent's network
  gone? What actually destroys a network namespace (and the veth)?
* Q2.7 — Start a container on Docker's default network
  (`docker run -d --name tmp alpine sleep 600`) and run `ip link` on the
  host again. What appeared, and where is its peer? (`ip link show master
  docker0`.) Clean up with `docker rm -f tmp`. Compare that design with
  the one used in this lab. (This needs Docker Engine. Rootless Podman's
  default network runs a user-space stack, pasta/slirp4netns, so no veth
  appears on the host.)
* Q2.8 — **What does the agent know about the world?** From the manager:
  ```sh
  snmpget -v2c -c public agent sysName.0 sysDescr.0 sysUpTime.0 \
          HOST-RESOURCES-MIB::hrSystemUptime.0 HOST-RESOURCES-MIB::hrSystemProcesses.0
  ```
  and on the host: `hostname`, `uname -a`, `uptime`,
  `ps -e --no-headers | wc -l`. For each value the agent reports, does it
  describe the **container** or the **host**? Explain each answer with
  the namespace table. (Hint: `sysDescr` mixes both.) If you ran an SNMP
  agent in a container to monitor a server, what would it get wrong?
* Q2.9 — **Build a namespace without Docker.** On the host:
  ```bash
  sudo unshare --uts --net --pid --fork --mount-proc sh
  hostname cave; hostname        # renamed... only in here
  ip link                        # what is there, and in what state?
  ps                             # which PID is your shell?
  exit
  hostname                       # and out here?
  ```
  Which namespaces did that command create? Compared with the agent
  container, what is still missing: its own filesystem, resource limits,
  a network link? Bonus: `sudo unshare --time --boottime 315360000 --fork
  uptime`. If Docker put the agent in a time namespace like this one,
  how would `hrSystemUptime.0` in Q2.8 change?

### 2.3 Capturing SNMP traffic with Wireshark

The SNMP packets exist only on the veth, inside the containers' network
namespaces (§2.2). Wireshark on Windows only sees Windows' own
interfaces, so it cannot capture there directly. Instead, `tcpdump`
(already in the images) captures on the manager's `eth0` and passes the
packets to Wireshark, either **as a file** (offline) or **through a
pipe** (live). Both ends of the veth see the same packets, so capturing
on the manager is enough: it sees requests, responses *and* traps.

Install Wireshark on Windows (<https://www.wireshark.org>). Then, in
Ubuntu, define a shortcut to it:

```bash
WS="/mnt/c/Program Files/Wireshark/Wireshark.exe"
```

(On native Linux, or Ubuntu with WSLg, a Linux Wireshark works too:
use `WS=wireshark`.)

#### Offline: capture to a file, then open it

```bash
# Terminal 1: capture SNMP (161) and notifications (162). Ctrl-C to stop.
docker exec -it manager tcpdump -ni eth0 -w /tmp/snmp.pcap 'udp port 161 or udp port 162'

# Terminal 2: generate traffic (snmpget, snmpwalk, snmptrap, ...)

# Copy the file out of the container and open it in Windows Wireshark
docker cp manager:/tmp/snmp.pcap ~/snmp.pcap
"$WS" "$(wslpath -w ~/snmp.pcap)"
```

`wslpath -w` converts the Linux path to the Windows path Wireshark needs
(`\\wsl.localhost\Ubuntu\home\...`). You can also run `explorer.exe ~`
and double-click the file.

#### Live: pipe tcpdump into Wireshark

```bash
docker exec manager tcpdump -ni eth0 -U -w - 'udp port 161 or udp port 162' | "$WS" -k -i -
```

| Option | Why |
|---|---|
| `-w -` | tcpdump writes pcap to stdout instead of a file |
| `-U` | flush every packet immediately (otherwise Wireshark waits for a full buffer) |
| `-k -i -` | Wireshark starts capturing at once, reading from stdin |
| **no `-t`** in `docker exec` | a terminal (tty) mangles the binary stream, and Wireshark reports `Frame ... too long` |

Packets appear in Wireshark as you run commands in another terminal.
Stop with Ctrl-C in the terminal running the pipe.

#### Show MIB names instead of numbers

Wireshark is like `snmpget`: it shows names only if it has the MIB
files. The manager already has all of them, including `GVR-LAB-MIB`, so
copy them out:

```bash
docker cp manager:/usr/share/snmp/mibs ~/gvr-mibs
wslpath -w ~/gvr-mibs          # copy this path
```

In Wireshark, open **Edit → Preferences → Name Resolution**:

1. Tick **Enable OID resolution**.
2. **SMI (MIB and PIB) paths → Edit… → +**, and paste the path.
3. **SMI (MIB and PIB) modules → Edit… → +**, and add `SNMPv2-MIB`,
   `IF-MIB` and `GVR-LAB-MIB` (one per line).
4. **Restart Wireshark.** The MIBs are only loaded at startup.

Before / after, for the same packet:

```
get-response 1.3.6.1.4.1.99999.1.2.1.3.2           (no MIBs)
get-response GVR-LAB-MIB::gvrLabRoomTemp.2         (MIBs loaded)
```

#### Decrypt SNMPv3

Open **Edit → Preferences → Protocols → SNMP → Users Table → Edit… → +**:

| Engine ID | Username | Authentication model | Password | Privacy protocol | Privacy password |
|---|---|---|---|---|---|
| *(empty = any)* | `gvrUser` | `SHA1` | `gvrAuthPass` | `AES` | `gvrPrivPass` |

The `encryptedPDU: privKey Unknown` lines turn into a normal
`get-request` / `get-response`.

#### Useful display filters

| Filter | Shows |
|---|---|
| `snmp` | all SNMP |
| `udp.port == 162` | notifications only (traps and informs, plus inform acknowledgements) |
| `snmp.data == 5` | GETBULK requests (0 get, 1 getnext, 2 response, 3 set, 5 getbulk, 6 inform, 7 trap, 8 report) |
| `snmp.community == "public"` | v1/v2c packets with that community |
| `snmp.name == 1.3.6.1.2.1.1.5.0` | packets that carry `sysName.0` |
| `snmp.msgUserName` | SNMPv3 packets |

**Questions** (capture while you do the exercises in §4 and §5):

* W1 — Pick a `get-request` and its `get-response`. Expand
  *Simple Network Management Protocol*: list every field of the PDU.
  Which field links the response to its request?
* W2 — Click the *Object Name* of a GET for `sysName.0` and look at the
  bytes pane: `06 08 2b 06 01 02 01 01 05 00`. What are `06` and `08`?
  Why does `1.3` take a single byte (`2b`)? Now find `99999` inside
  `GVR-LAB-MIB::gvrLabRoomTemp.2`. Why does it take three bytes
  (`86 8d 1f`)? (Hint: 7 bits per byte, and the high bit means "more
  bytes follow".)
* W3 — Open a GETBULK request. Which two fields appear where a GET has
  `error-status` and `error-index`?
* W4 — Capture one `snmptrap` and one `snmpinform` (§4.5). Which one
  gets an answer? What are the first two varbinds of both?
* W5 — Capture an SNMPv3 GET *before* configuring the Users Table. What
  can you still read (user name, engine ID, the discovery `Report`)?
  Then add the user. What does it take to read "encrypted" SNMP, and
  what does that say about protecting the passwords?
* W6 — Compare the same packet with and without the MIBs loaded. Did
  any byte on the wire change?

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
| Docker Desktop: `lab.sh up` fails in `nsenter` | Use Ubuntu on WSL2 with Docker Engine installed inside Ubuntu (§0.1) |
| `/usr/bin/env: 'bash\r'` or `exec /entrypoint.sh: no such file or directory` | Windows line endings: `sed -i 's/\r$//' lab.sh */entrypoint.sh`, then `./lab.sh build` (§0.1) |
| WSL: `sudo nsenter -t $PA ...` fails or shows the wrong process | `docker info --format '{{.OperatingSystem}}'` says "Docker Desktop": use the host shell from §2.2 |
| `./lab.sh: Permission denied` | `chmod +x lab.sh`, or run `bash lab.sh ...`. Better: clone inside WSL, not in `/mnt/c` |

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
