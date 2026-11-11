// Package discovery publishes address hints, never pairing credentials or trust.
package discovery

import (
	"errors"
	"net"
	"regexp"
	"strings"

	zeroconf "github.com/libp2p/zeroconf/v2"
)

const ServiceType = "_micdrop._tcp"

type Record struct {
	Instance string
	Hostname string
	Address  string
	Port     int
	TXT      []string
}

// RecordFor publishes only the endpoint, versions, and public host-key hint.
func RecordFor(ip net.IP, port int, key string) (Record, error) {
	if ip.To4() == nil || !ip.IsPrivate() || port < 1 || port > 65535 || !regexp.MustCompile(`^[0-9a-f]{64}$`).MatchString(key) {
		return Record{}, errors.New("invalid discovery endpoint or public identity")
	}
	name := "MicDrop-" + key[:12]
	return Record{Instance: name, Hostname: strings.ToLower(name) + ".local.", Address: ip.String(), Port: port,
		TXT: []string{"v=1", "p=3", "id=" + key}}, nil
}

// MatchInterface must never fall back to advertising on every adapter.
func MatchInterface(ip net.IP, interfaces []net.Interface, addresses func(net.Interface) ([]net.Addr, error)) (net.Interface, error) {
	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagMulticast == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := addresses(iface)
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			candidate, _, err := net.ParseCIDR(addr.String())
			if err == nil && candidate.Equal(ip) {
				return iface, nil
			}
		}
	}
	return net.Interface{}, errors.New("no multicast interface owns the listening address")
}

type Advertisement struct {
	server *zeroconf.Server
	Name   string
}

func Start(ip net.IP, port int, key string) (*Advertisement, error) {
	record, err := RecordFor(ip, port, key)
	if err != nil {
		return nil, err
	}
	interfaces, err := net.Interfaces()
	if err != nil {
		return nil, err
	}
	iface, err := MatchInterface(ip, interfaces, func(i net.Interface) ([]net.Addr, error) { return i.Addrs() })
	if err != nil {
		return nil, err
	}
	server, err := zeroconf.RegisterProxy(record.Instance, ServiceType, "local", record.Port,
		record.Hostname, []string{record.Address}, record.TXT, []net.Interface{iface}, zeroconf.TTL(120))
	if err != nil {
		return nil, err
	}
	return &Advertisement{server: server, Name: record.Instance}, nil
}

func (a *Advertisement) Close() {
	if a != nil {
		a.server.Shutdown() // Sends goodbye records and waits for the responder to stop.
	}
}
