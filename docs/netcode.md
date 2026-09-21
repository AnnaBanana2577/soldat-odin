# Netcode, as built

The model is in the readme: server-authoritative snapshots, client-side prediction
and interpolation delay, on a fixed timestep. This is each piece of it as it is
actually built.

- A client sends the commands the server has not run, all of them in every packet so
  a lost one costs nothing, with the server tick it is showing the others at (Input).
  What it chooses outside its keys goes once, reliably (Act): its weapons, its team.
  The server tells everyone who plays in which slot, by name, whenever someone joins
  (Roster).
- The server runs each soldier on the commands its queue gives for that tick
  (server/queue.odin), and three rules there are what make the prediction hold:
  - **A starved queue steps nobody.** While a living soldier's commands are in
    flight it is not stepped at all, so it ends up exactly where its client
    predicted, however late they come. Stepping it with anything else (the last
    command again, a neutral one) moves it here where the client did not, and every
    such tick is a correction the client swallows when the commands land: that is
    the pull-back a player feels under packet loss.
  - **A burst runs in one tick.** Commands held up and landing together run down to
    the depth the client's clock aims for, so a stall costs nothing lasting.
  - **A quiet client's keys are let go** after half a second, so a soldier whose
    player has gone away falls and stops instead of hanging in the air.
- The client runs its clock a shade faster or slower to keep about two commands
  waiting on the server: enough to ride out jitter, not enough to be felt. Every
  update carries the last command the server ran and how many were waiting.
- My own bullets stay on my own timeline: I fired them from the same command the
  server did, so they are usually where its are anyway. When the server says where one
  ended, mine ends there too, which is where it was ruled to hit or miss.
- Prediction is only as good as what the server's word covers, so an update carries
  the receiver's own soldier whole, every tick, and a test holds the wire's three
  parts (served, owned, rest) to the whole soldier, so no field can quietly drift
  (shared/net/soldier_halves_test.odin). Where the server disagrees the difference
  is drawn as an offset that blends out in about a tenth of a second.
- Rounds. A round ends at its score or time limit; the scores stand for five seconds
  and a third, counted down in the round, and the next round begins on the next map
  of the server's rotation (-map a,b,c), or the same one. The server loads it and
  tells everyone which it is and where its flags stand (Map), then, in that order on
  the same channel, the things and everyone's placing with a nil tally. Joining is
  hearing of the first Map, so a newcomer and a round's start are one path: a client
  has no map until the server names one, the picture is rebuilt whenever the game
  loads another, and an update from before the Map is of the last round and dropped.
  Every placing of a soldier (a spawn, a respawn, a new round) is told as a fact and
  every client places that soldier on it, so nobody lingers where they were.
- The server steps every soldier every tick: its bots on their brain's command, and
  the players on the commands their queues give for that tick. Because its world has
  authority, what those steps cause counts: a wound from lava, a fall off the map, a
  bullet fired. Nothing a client sends is taken on trust, because nothing but the keys
  is sent: the server runs the sim itself.
- Every other tick each client gets an Update: which slots are in play, the soldiers
  in its view (its own with only the server's half: health, death, the flag, the
  tally), the ones out of view twice a second, and the bullets born lately whose line
  of flight passes near it, each in three updates running and numbered so it flies
  once. A thing goes out whole when it appears or goes, changes hands, or starts or
  stops moving (Things); in between every machine runs the same physics on it. What
  only the server could decide goes out as a fact (Facts), and sounds and shows like
  anything else that happened; what a pickup gives of the things a client owns (a
  gun, grenades) the client gives itself on hearing of it.
- Time. A client shows the others at a view tick a few ticks behind the newest word
  of them, drawn between the two words around it, so nothing about them is guessed and
  nothing taken back; how far behind follows the line, three ticks on a good one
  (client/game/view.odin). Every Input names that tick, and the
  difference from the tick it arrives in is the client's lag, measured per packet. A
  bullet keeps the lag of the packet it came in and meets the soldiers as they were
  that long ago (sim/history.odin), for as long as it flies, up to a cap (sv_maxrewind,
  300 ms by default; past it a shooter leads). The others fly that bullet on by the
  ticks since its birth, its shooter's lag and their own: the server will rule it
  against me as I was my own lag ago, so the bullet that will be ruled to hit me is
  that far ahead of the one the server spawned. Soldat's rule: my ping plus the
  shooter's. The shove of a hit on me comes with the server's word on my soldier,
  as the wound does: shoving myself where I see the bullet land would be a guess at a
  tick the server has not reached.
- Lives. The server places a soldier (a spawn, a respawn, a correction) and each
  placing begins a new life, numbered. A client says which life its word is of and
  takes the server's word of its own soldier only for the life it is living, so word
  from before a placing is never taken for word from after it, whichever way the
  packets cross.
- Every message is state or news, and RELIABLE in shared/net/protocol.odin says
  which; no call site chooses. Each has one serialize procedure, used for reading
  and writing both, bounds-checked, that refuses floats that are not numbers, enums
  out of range, counts too large and bytes left over (shared/net/protocol_test.odin).
- ENet only sends what it was given when it is next pumped, a tick later; both ends
  flush at the end of their tick, which took two ticks off everyone's lag.
- Measured with the headless client against five dodging bots on Arena, ninety
  seconds a run. Prediction: in a fight on a clean line the client's own soldier sits
  0.00 units from the server's on average (0.34 at worst) over 5000 updates, and 0.10
  on a 120 ms line with 5% loss. Under 30% packet loss at 200 ms it is 0.03, and under
  50% loss at 300 ms 0.06: the starved-queue rule doing its work. Hits: on the clean
  line 21 of the 21 it saw itself give were ruled, and 10 of the 11 it took; on the
  120 ms line 14 of 15 given and 22 of 24 taken. The others sit three ticks behind the
  newest word of them. 3 KB/s up on a clean line (8 when the unrun commands pile up)
  and 30 KB/s down with six soldiers in view.
