package connection

import "core:fmt"
import "core:strings"
import "core:time"
import enet "vendor:ENet"
import "../../shared/net"

// The link to the server: ENet, the handshake, and a queue of received packets that
// the game drains once per tick, so every message is applied at a tick boundary and
// in order. A simulated bad line (simulate_line) can sit on it, for testing.
Connection :: struct {
	host:     ^enet.Host,
	peer:     ^enet.Peer,
	slot:     u8,
	inbox:    [dynamic][]u8, // copies of received packets, owned here until drained
	fake:     net.Fake_Link,
	lost:     bool, // the server went away
}

CONNECT_TIMEOUT :: 4 * time.Second

// Connects and completes the handshake before returning: hello up, welcome down.
open :: proc(c: ^Connection, address: string, port: u16, name: string) -> bool {
	if enet.initialize() != 0 do return false
	c.host = enet.host_create(nil, 1, net.CHANNEL_COUNT, 0, 0)
	if c.host == nil do return false
	addr: enet.Address
	if enet.address_set_host(&addr, strings.clone_to_cstring(address, context.temp_allocator)) != 0 do return false
	addr.port = port
	c.peer = enet.host_connect(c.host, &addr, net.CHANNEL_COUNT, 0)
	if c.peer == nil do return false

	deadline := time.tick_now()
	event: enet.Event
	for time.tick_since(deadline) < CONNECT_TIMEOUT {
		if enet.host_service(c.host, &event, 50) <= 0 do continue
		#partial switch event.type {
		case .CONNECT:
			// ENet's throttle off for our side too, as the server does for its side
			enet.peer_throttle_configure(c.peer, enet.PEER_PACKET_THROTTLE_INTERVAL, 0, 0)
			c.peer.packetThrottle = enet.PEER_PACKET_THROTTLE_SCALE
			send_message(c, net.Hello{version = net.VERSION, name = name})
		case .RECEIVE:
			reply: net.Message
			decoded := net.decode(event.packet.data[:event.packet.dataLength], &reply)
			defer enet.packet_destroy(event.packet)
			if !decoded do continue
			#partial switch m in reply {
			case net.Welcome:
				c.slot = m.slot
				return true
			case net.Denied:
				fmt.eprintfln("server refused: %s", m.reason)
				return false
			}
		case .DISCONNECT:
			return false
		}
	}
	return false
}

close :: proc(c: ^Connection) {
	if c.peer != nil do enet.peer_disconnect(c.peer, 0)
	if c.host != nil {
		enet.host_flush(c.host)
		enet.host_destroy(c.host)
	}
	for p in c.inbox do delete(p)
	delete(c.inbox)
	net.fake_destroy(&c.fake)
	enet.deinitialize()
}

// A round trip of `ping` ms, up to `jitter` more at random, `loss` percent of the
// packets lost: between this client and the server, both ways.
simulate_line :: proc(c: ^Connection, ping, jitter, loss: f64) {
	net.fake_init(&c.fake, ping, jitter, loss)
}

// Pumps ENet and returns everything that arrived, oldest first. The slice is valid
// until the next call. With the fake line on, arrivals wait their delay here and the
// packets held back from sending go out once theirs is up.
receive :: proc(c: ^Connection) -> [][]u8 {
	for p in c.inbox do delete(p)
	clear(&c.inbox)
	event: enet.Event
	for enet.host_service(c.host, &event, 0) > 0 {
		#partial switch event.type {
		case .RECEIVE:
			data := make([]u8, event.packet.dataLength)
			copy(data, event.packet.data[:event.packet.dataLength])
			if !c.fake.on do append(&c.inbox, data)
			else if !net.fake_hold(&c.fake, &c.fake.incoming, &c.fake.reliable_in, data, event.channelID == net.CHANNEL_RELIABLE) do delete(data)
			enet.packet_destroy(event.packet)
		case .DISCONNECT:
			c.lost = true
		}
	}
	if c.fake.on {
		released: [dynamic]net.Held
		defer delete(released)
		net.fake_release(&c.fake.incoming, &released)
		for h in released do append(&c.inbox, h.data)
		clear(&released)
		net.fake_release(&c.fake.outgoing, &released)
		for h in released {
			send_now(c, h.data, h.reliable)
			delete(h.data)
		}
		flush(c)
	}
	return c.inbox[:]
}

// ENet only queues what it is given and sends it the next time it is pumped, which is
// a tick away: what this tick queued goes now.
flush :: proc(c: ^Connection) {
	enet.host_flush(c.host)
}

// A message, on the delivery its kind has.
send_message :: proc(c: ^Connection, msg: net.Message) {
	m := msg
	buf: [net.MAX_PACKET]u8
	if size, ok := net.encode(buf[:], &m); ok do send(c, buf[:size], net.RELIABLE[net.message_kind(&m)])
}

send :: proc(c: ^Connection, data: []u8, reliable: bool) {
	if c.fake.on {
		held := make([]u8, len(data))
		copy(held, data)
		if !net.fake_hold(&c.fake, &c.fake.outgoing, &c.fake.reliable_out, held, reliable) do delete(held)
		return
	}
	send_now(c, data, reliable)
}

@(private = "file")
send_now :: proc(c: ^Connection, data: []u8, reliable: bool) {
	flags := enet.PacketFlags{.RELIABLE} if reliable else enet.PacketFlags{.UNRELIABLE_FRAGMENT}
	packet := enet.packet_create(raw_data(data), len(data), flags)
	enet.peer_send(c.peer, reliable ? net.CHANNEL_RELIABLE : net.CHANNEL_UNRELIABLE, packet)
}
