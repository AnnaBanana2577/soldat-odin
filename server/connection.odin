package server

import enet "vendor:ENet"
import "../shared/net"
import "../shared/sim"

// The ENet host and the peers by slot. A peer that has connected but not yet said
// hello has no slot: its packets arrive with NO_SLOT and the game assigns one on the
// hello. Received packets are queued and drained once per tick, so everything is
// applied at tick boundaries and in arrival order.

NO_SLOT :: 255

Host :: struct {
	host:  ^enet.Host,
	peers: [sim.MAX_PLAYERS]^enet.Peer,
	inbox: [dynamic]Received,
	left:  [dynamic]u8, // slots whose peer disconnected since the last tick
}

Received :: struct {
	slot: u8, // NO_SLOT before the hello
	peer: ^enet.Peer,
	data: []u8,
}

host_open :: proc(h: ^Host, port: u16) -> bool {
	if enet.initialize() != 0 do return false
	addr := enet.Address{host = 0, port = port} // ENET_HOST_ANY
	h.host = enet.host_create(&addr, sim.MAX_PLAYERS, net.CHANNEL_COUNT, 0, 0)
	return h.host != nil
}

host_close :: proc(h: ^Host) {
	if h.host != nil do enet.host_destroy(h.host)
	for p in h.inbox do delete(p.data)
	delete(h.inbox)
	delete(h.left)
	enet.deinitialize()
}

// Pumps ENet and returns everything that arrived since the last call, oldest first;
// the slice is valid until the next call. Disconnected slots collect in `left`.
host_receive :: proc(h: ^Host) -> []Received {
	for p in h.inbox do delete(p.data)
	clear(&h.inbox)
	clear(&h.left)
	event: enet.Event
	for enet.host_service(h.host, &event, 0) > 0 {
		#partial switch event.type {
		case .RECEIVE:
			data := make([]u8, event.packet.dataLength)
			copy(data, event.packet.data[:event.packet.dataLength])
			append(&h.inbox, Received{u8(slot_of(h, event.peer)), event.peer, data})
			enet.packet_destroy(event.packet)
		case .DISCONNECT:
			if slot := slot_of(h, event.peer); slot != NO_SLOT {
				h.peers[slot] = nil
				append(&h.left, u8(slot))
			}
		}
	}
	return h.inbox[:]
}

// A free slot for a peer that said hello, or NO_SLOT when full.
host_assign :: proc(h: ^Host, peer: ^enet.Peer) -> u8 {
	for p, i in h.peers {
		if p == nil {
			h.peers[i] = peer
			return u8(i)
		}
	}
	return NO_SLOT
}

slot_of :: proc(h: ^Host, peer: ^enet.Peer) -> int {
	for p, i in h.peers do if p == peer do return i
	return NO_SLOT
}

host_send :: proc(h: ^Host, slot: u8, data: []u8, reliable: bool) {
	if slot == NO_SLOT do return
	peer_send(h.peers[slot], data, reliable)
}

host_broadcast :: proc(h: ^Host, data: []u8, reliable: bool) {
	for p in h.peers do if p != nil do peer_send(p, data, reliable)
}

peer_send :: proc(peer: ^enet.Peer, data: []u8, reliable: bool) {
	if peer == nil do return
	flags := enet.PacketFlags{.RELIABLE} if reliable else enet.PacketFlags{.UNRELIABLE_FRAGMENT}
	packet := enet.packet_create(raw_data(data), len(data), flags)
	enet.peer_send(peer, reliable ? net.CHANNEL_RELIABLE : net.CHANNEL_UNRELIABLE, packet)
}
