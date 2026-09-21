# Vision

Soldat has been played for over twenty years, and it has been open source since 2020,
which is the only reason a project like this one can exist. It is also a large Pascal
codebase grown over two decades, and changing anything in it means threading the change
through all of that history. That is slow going for anyone, and it is a fair description
of most long-lived games rather than a complaint about this one.

This is an attempt from the other end. The same game, moved to a modern language and
arranged so you can find the part you are looking for, with the netcode rebuilt properly
rather than patched around, and the tools for making things built into the game itself.

The goal is to make it easy to iterate on: for me, and for anyone else who wants to.
Someone who would like to make maps, or a game mode that never existed, or a different
look for the interface, or who just wants to read how the netcode works and take the
ideas somewhere else. That is why the code is arranged the way it is, why the commit
bodies carry their reasoning, and why these docs exist. If you want to build something
with it, you are who it is for.

## The pieces

**The game.** An Odin port on raylib and ENet: the client, the server, and a simulation
both share so that every machine steps the same world the same way. The netcode is the
Quake 3 model on a fixed timestep, which is the readme's subject.

**The tools**, in the game's own binary, drawing with the game's own renderer. A map
editor is here. A `.po` and `.poa` editor, for the gostek's objects and the animations
that move them, and a mod maker for putting art, sounds and weapon settings together,
are to come. Each works the same way: it owns the file as it really is, and everything
on screen is derived from those bytes through the codec the game reads, so a field a
tool would lose shows up on screen rather than quietly on disk.

**A lobby and master server,** in Go, and **a gather bot** for Discord. Neither is
started and neither is designed yet; they are named here because they are part of what
this is for. Finding a game, and getting enough people into one at the same time, is
most of whether a small community plays at all. Soldat has had both for years and has
them still; this is a separate game with its own wire, and it wants its own.

The pieces stay separate on purpose. The game will not depend on the lobby existing,
and a community that wants none of it can run a server and give out its address as
people always have.
