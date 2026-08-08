package main

import (
	"bufio"
	"fmt"
	"os/exec"
	"strconv"
	"strings"
)

// interfaceTotals returns cumulative received/sent byte counts across the
// machine's physical network interfaces.
//
// This shells out to netstat(1) instead of reading the kernel's if_data64 out of
// a NET_RT_IFLIST2 sysctl. The direct route was tried first and abandoned: the
// byte counters could not be located anywhere in the RTM_IFINFO2 message when
// the parsed values were checked against netstat's own output, and
// golang.org/x/net/route does not expose interface statistics at all. gopsutil
// shells out on darwin for the same reason. One short-lived process per second
// is negligible next to the ~235 Mbps of synthetic traffic this replaces.
func interfaceTotals() (in uint64, out uint64, err error) {
	output, err := exec.Command("/usr/sbin/netstat", "-ib").Output()
	if err != nil {
		return 0, 0, fmt.Errorf("netstat: %w", err)
	}

	seen := make(map[string]bool)
	scanner := bufio.NewScanner(strings.NewReader(string(output)))
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		// Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
		if len(fields) < 10 {
			continue
		}
		name := fields[0]
		if seen[name] || !isPhysicalInterface(name) {
			continue
		}
		// Only the <Link#n> row carries interface-wide totals. The per-protocol
		// rows that follow repeat a subset of the same bytes and would double
		// count them.
		if !strings.HasPrefix(fields[2], "<Link") {
			continue
		}
		ibytes, errIn := strconv.ParseUint(fields[6], 10, 64)
		obytes, errOut := strconv.ParseUint(fields[9], 10, 64)
		if errIn != nil || errOut != nil {
			continue
		}
		seen[name] = true
		in += ibytes
		out += obytes
	}
	if err := scanner.Err(); err != nil {
		return 0, 0, err
	}
	if len(seen) == 0 {
		return 0, 0, fmt.Errorf("no physical interfaces found in netstat output")
	}
	return in, out, nil
}

// isPhysicalInterface keeps Ethernet and Wi-Fi (en*) and excludes loopback,
// tunnels (utun*, gif*, stf*), AirDrop (awdl*, llw*), bridges and virtual
// adapters. Counting a VPN tunnel alongside the physical interface it rides on
// would double count every byte.
func isPhysicalInterface(name string) bool {
	switch {
	case strings.HasPrefix(name, "awdl"), strings.HasPrefix(name, "llw"):
		return false
	case strings.HasPrefix(name, "en"), strings.HasPrefix(name, "eth"):
		return true
	default:
		return false
	}
}

// deltaBytes handles the counter reset that happens when an interface goes down
// or the machine sleeps: a decrease is reported as no traffic rather than as a
// huge negative spike wrapped into a uint64.
func deltaBytes(current, previous uint64) int64 {
	if current < previous {
		return 0
	}
	return int64(current - previous)
}
