Making a 2D multiplayer game in Odin. Is it good to just have a file for each entity with a step function, that gets passed a pointer to the word (which has all the entities) so it can access them and adjust their health, check collision, etc)? Or is that a messy way of doing things

Yes — that is a perfectly reasonable architecture for a small/medium 2D multiplayer game in Odin, and honestly it can be much cleaner than introducing an elaborate ECS or component framework.

I’d make one important distinction, though:

Let entities have step() functions, but be careful about letting every entity freely mutate every other entity.

A structure like this is quite nice:

World :: struct {
    players: []Player,
    bullets: []Bullet,
    grenades: []Grenade,
    pickups: []Pickup,
    walls: []Wall,
    ...
}

Player :: struct {
    pos:     Vec2,
    vel:     Vec2,
    health:  i32,
    ...
}

player_step :: proc(p: ^Player, world: ^World, dt: f32) {
    // read input
    // movement
    // collision
    // maybe interact with other entities
}

Then your main simulation is basically:

world_step :: proc(w: ^World, dt: f32) {
    for &player in w.players {
        player_step(&player, w, dt)
    }

    for &bullet in w.bullets {
        bullet_step(&bullet, w, dt)
    }

    for &grenade in w.grenades {
        grenade_step(&grenade, w, dt)
    }
}

That's simple, explicit, and very Odin-like.

Where I'd draw the line

I wouldn't have something like:

player_step :: proc(p: ^Player, world: ^World, dt: f32) {
    // ...
    world.players[3].health -= 50
    world.bullets[8].destroyed = true
    world.pickups[2].active = false
    world.some_random_system.foo = ...
}

everywhere.

It works, but eventually your entity code becomes coupled to the entire game.

Instead, I'd use the World pointer primarily as the simulation context:

player_step :: proc(p: ^Player, world: ^World, dt: f32) {
    // Query world
    hits := world_query_collision(world, p.pos, ...)

    // Produce effects
    if hit_enemy {
        damage(world, enemy_id, 25)
    }
}

So you can have a small collection of world-level operations:

damage(world, entity_id, amount)
destroy_entity(world, entity_id)
spawn_bullet(world, ...)
spawn_explosion(world, ...)
pickup_item(world, player_id, item_id)

That gives you a nice middle ground.

An architecture I think would fit your game particularly well

Given the kind of fixed-timestep server simulation you've been describing, I'd probably organize it something like:

game/
    world.odin

    player.odin
    bullet.odin
    grenade.odin
    pickup.odin
    flag.odin

    collision.odin
    damage.odin
    weapons.odin
    physics.odin

    input.odin

And conceptually:

                 World
                   │
       ┌───────────┼───────────┐
       ↓           ↓           ↓
    Players      Bullets     Pickups
       │           │           │
    step()       step()       step()
       │           │           │
       └───────────┼───────────┘
                   ↓
             World queries
             World mutations

The World owns the state.

Entities contain their own behavior.

Systems/helpers handle things that don't naturally belong to one entity.

That's a very comfortable architecture for a game that isn't enormous.

And you don't necessarily need an ECS

For example, I'd be totally happy with:

World :: struct {
    players:  []Player,
    bullets:  []Bullet,
    grenades: []Grenade,
    flags:    []Flag,
    pickups:  []Pickup,
}

rather than:

Entity
 ├── Transform component
 ├── Physics component
 ├── Health component
 ├── Weapon component
 └── ...

For a game like yours, the former can be much easier to reason about.

You also get a major benefit for multiplayer:

simulate_server(world, inputs)
simulate_client(world, inputs)

can operate on essentially the same World and entity simulation code.

Your renderer doesn't need to know anything about simulation internals:

render(world)

And networking can serialize the relevant pieces of World:

write_snapshot(world, writer)
read_snapshot(&world, reader)

That's a really clean separation.

One thing I'd strongly recommend

Give entities stable IDs, rather than having entity code identify things by array index:

Entity_ID :: distinct u32

Player :: struct {
    id: Entity_ID,
    pos: Vec2,
    ...
}

Then:

damage(world, target_id, 25)

is much safer than:

world.players[3].health -= 25

especially once things can be spawned/destroyed.

So: yes, your basic idea is good. I'd call it a World + entity behavior architecture rather than a messy design. The trick is keeping the World pointer from becoming a giant bag of arbitrary mutations; give it a small, deliberate API for querying and changing simulation state.

Yep. That's exactly how I'd do it. I overcomplicated world_step in the previous example by introducing players_step, bullets_step, etc.

The simple version is:

world_step :: proc(w: ^World, inputs: []Input, dt: f32) {
    for &player in w.players {
        player_step(&player, w, inputs[player.id], dt)
    }

    for &bullet in w.bullets {
        bullet_step(&bullet, w, dt)
    }

    for &grenade in w.grenades {
        grenade_step(&grenade, w, dt)
    }

    for &pickup in w.pickups {
        pickup_step(&pickup, w, dt)
    }

    for &flag in w.flags {
        flag_step(&flag, w, dt)
    }

    // cleanup dead/destroyed entities
}

So conceptually:

tick
  ↓
match_step
  ↓
world_step
  ├── player_step
  ├── bullet_step
  ├── grenade_step
  ├── pickup_step
  └── flag_step

And each entity gets:

entity_step(entity, world, ...)

The World is the simulation container and orchestrator, while each entity owns its behavior.

That's actually a really nice sweet spot:

Game = World + Match
Match = lifecycle/rules
World = entities + simulation
Entity step() = entity behavior
Server = networking/server loop
Client = networking/input/rendering/client loop

No need for "systems" unless you eventually discover a reason for them.

One thing you will eventually need to decide is step ordering. For example, whether bullets see players after players have moved, whether pickups happen before/after movement, etc. But that's just a natural part of world_step, and you can make the ordering explicit.

Today 8:42 AM
If my game had a hud, and client also had map editor, and other tools, what’s best way to structure?

Game struct has a HUD struct? Client has a var for current mode: editor, game, other tools?

Yeah — I'd keep the HUD and editor/tooling out of Game. Your instinct about a Client mode is right.

I'd make the separation:

Server
├── config
├── network
└── game
    ├── world
    └── match

Client
├── network
├── game
├── input
├── renderer
├── hud
├── editor
└── mode

Where Game remains pure game simulation:

Game :: struct {
    world: World,
    match: Match,
}

And the client is the application that uses the game.

Client mode

Something like:

Client_Mode :: enum {
    Game,
    Editor,
    Console,
    Settings,
    Main_Menu,
}

Then:

Client :: struct {
    game: Game,

    network: Network,
    input: Input,
    renderer: Renderer,

    hud: HUD,
    editor: Editor,

    mode: Client_Mode,
}

And your client loop can dispatch based on mode:

client_step :: proc(c: ^Client, dt: f32) {
    input_step(&c.input)

    switch c.mode {
    case Game:
        game_client_step(c, dt)

    case Editor:
        editor_step(&c.editor, &c.input, dt)

    case Console:
        console_step(...)

    case Settings:
        settings_step(...)
    }
}
One refinement: HUD is usually tied to Game mode

I'd probably still have:

Client :: struct {
    game: Game,
    hud: HUD,
    editor: Editor,
    ...
}

rather than putting:

Game :: struct {
    world: World,
    match: Match,
    hud: HUD, // ❌
}

because the server should be able to run Game with zero knowledge that a HUD exists.

The HUD can simply read the game:

hud_draw :: proc(hud: ^HUD, game: ^Game) {
    draw_health(game.world, ...)
    draw_score(game.match, ...)
    draw_timer(game.match, ...)
}

That's a very clean relationship:

Game
  ↑
  │ reads
  │
HUD

rather than:

Game
 └── HUD
The editor is slightly different

Your editor probably shouldn't even depend on a running Game unless you're specifically editing a live game.

You might have:

Editor :: struct {
    map: Map,
    selected: Entity_ID,
    tool: Editor_Tool,
    camera: Camera,
}

Then:

Client
│
├── Game       ← actual simulation
│
├── HUD        ← presentation of Game
│
├── Editor     ← map/content authoring
│
└── Mode       ← which application state is active

And eventually you could have:

Client_Mode :: enum {
    Menu,
    Game,
    Editor,
}

with the mode determining which client subsystem gets input/update/render time.

The important architectural principle is:

Game is the game. Client is the application that displays and manipulates the game.

That distinction gives you a lot of freedom.

Your dedicated server can literally be:

Server → Game → World + Match

while your desktop client is:

Client
├── Game
├── HUD
├── Renderer
├── Editor
├── Audio
└── Input

And later you could make a headless test runner:

Test
└── Game

No renderer, no networking, no HUD, no editor.

That's a very clean architecture for Odin because you're not creating abstractions just for the sake of abstraction. Each struct has a pretty obvious reason to exist.

But hud only runs when game runs, so I felt for client hud should be in game. Client and server can define their own game struct, they just share world and match?

Yes — I think your model is actually cleaner given what you're building.

The key distinction is that Game doesn't necessarily have to mean "simulation only." It can mean "the game experience/application state," while World + Match are the shared simulation core.

I'd structure it like this:

World :: struct {
    players: []Player,
    bullets: []Bullet,
    flags: []Flag,
    // ...
}

Match :: struct {
    mode: Match_Mode,
    state: Match_State,
    score: [2]i32,
    // rules/lifecycle
}

Then the server and client can compose those differently:

Server_Game :: struct {
    world: World,
    match: Match,
}
Client_Game :: struct {
    world: World,
    match: Match,

    hud: HUD,
    camera: Camera,
    // client-only game presentation/state
}

And:

Server :: struct {
    config: Server_Config,
    network: Network,
    game: Server_Game,
}
Client :: struct {
    network: Network,
    input: Input,
    renderer: Renderer,
    audio: Audio,

    mode: Client_Mode,
    game: Client_Game,
    editor: Editor,
    // other tools
}
This gives you a really nice layering
                  ┌───────────────┐
                  │     World     │
                  └───────┬───────┘
                          │
                  ┌───────▼───────┐
                  │     Match     │
                  └───────┬───────┘
                          │
                 shared simulation
                    Game pieces
                          │
             ┌────────────┴────────────┐
             │                         │
      ┌──────▼──────┐          ┌───────▼──────┐
      │ Server_Game │          │ Client_Game  │
      │             │          │              │
      │ World       │          │ World        │
      │ Match       │          │ Match        │
      │             │          │ HUD          │
      │             │          │ Camera       │
      └──────┬──────┘          └───────┬──────┘
             │                         │
          Server                    Client

And importantly, World and Match aren't duplicated conceptually. They're the shared game state/model. The outer Server_Game and Client_Game are just different compositions around that core.

I'd probably even call the shared thing Game_State

For example:

Game_State :: struct {
    world: World,
    match: Match,
}

Then:

Server_Game :: struct {
    state: Game_State,
}
Client_Game :: struct {
    state: Game_State,

    hud: HUD,
    camera: Camera,
}

But honestly, that's only worth doing if Game_State gives you a useful name. You don't need another abstraction just because you can make one.

Your intuition about the HUD is particularly good: if HUD is specifically the HUD for the running game, having it owned by Client_Game makes semantic sense.

Then your client mode becomes very clean:

Client_Mode :: enum {
    Game,
    Editor,
    Console,
    Menu,
}
Client :: struct {
    mode: Client_Mode,

    game: Client_Game,
    editor: Editor,

    network: Network,
    input: Input,
    renderer: Renderer,
    audio: Audio,
}

So:

client_update :: proc(c: ^Client, dt: f32) {
    switch c.mode {
    case .Game:
        client_game_update(&c.game, &c.input, dt)

    case .Editor:
        editor_update(&c.editor, &c.input, dt)

    case .Console:
        console_update(...)

    case .Menu:
        menu_update(...)
    }
}

And:

client_draw :: proc(c: ^Client) {
    switch c.mode {
    case .Game:
        client_game_draw(&c.game, &c.renderer)

    case .Editor:
        editor_draw(&c.editor, &c.renderer)

    case .Console:
        console_draw(...)

    case .Menu:
        menu_draw(...)
    }
}

That feels very Odin-like to me: explicit structs, straightforward ownership, no scene hierarchy, no interfaces, no ECS required.

The really nice part is that your simulation functions can remain shared:

tick
match_step
world_step
player_step
bullet_step
flag_step

while the client-specific stuff sits above them:

Client
└── Client_Game
    ├── Game state
    │   ├── World
    │   └── Match
    │
    ├── HUD
    └── Camera

So I'd revise my earlier recommendation: yes, putting HUD in Client_Game is probably better for your architecture than putting it directly on Client. The Client is the application; Client_Game is the running game experience.
