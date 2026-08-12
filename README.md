# Arcane Automata

Arcane Automata is a visual-only Ashita v4 addon for HorizonXI. It renders the
Puppetmaster's active maneuvers as elemental orbs above the local character,
inspired by Invoker's orbiting elements in Dota 2.

The addon does not use abilities, automate actions, or send gameplay commands.

## Load

```text
/addon load arcaneautomata
```

The primary short command is `/aa`. The previous `/po`, `/puporbit`,
`/invokation`, and `/inv` commands remain accepted for compatibility.

## Commands

```text
/aa on
/aa off
/aa toggle
/aa style crown
/aa style orbit
/aa icons runes
/aa icons crests
/aa icons mechanical
/aa icons toggle
/aa preset taru
/aa preset compact
/aa preset cinematic
/aa radius 55
/aa height 35
/aa speed 0.15
/aa scale 1.0
/aa offset -120
/aa idleoffset 18
/aa timers on
/aa timers off
/aa recast on
/aa recast off
/aa effects on
/aa effects off
/aa transitions on
/aa transitions off
/aa smoothing 0.12
/aa burden on
/aa burden off
/aa lattice on
/aa lattice off
/aa deployfx on
/aa deployfx off
/aa deployfx toggle
/aa deploystyle seals
/aa deploystyle chevrons
/aa deployorbit on
/aa deployorbit off
/aa deployorbit toggle
/aa orbitspeed 0.06
/aa confirmflash on
/aa confirmflash off
/aa confirmflash toggle
/aa colorblind on
/aa colorblind off
/aa fallback on
/aa fallback off
/aa safearea on
/aa safearea off
/aa autohide on
/aa autohide off
/aa test on
/aa test off
/aa test status
/aa test count 1
/aa test count 2
/aa test count 3
/aa test risk low
/aa test risk warm
/aa test risk danger
/aa test risk overload
/aa test set fire ice thunder
/aa test recast
/aa test deploy on
/aa test deploy off
/aa test deploy toggle
/aa test flash
/aa test flash ice
/aa reset
/aa help
```

Settings persist per Ashita profile. Maneuver state is intentionally transient.
Vertical placement is screen-relative: negative offsets move the formation
above the character's model origin and positive offsets move it downward. The
accepted range is -500 to 500 pixels, allowing per-race and per-camera tuning.
`idleoffset` is applied while not engaged; its default of 18 pixels lowers the
formation slightly without changing the combat placement. Engagement changes
blend smoothly between the two positions instead of snapping. Set it to zero
to use the same placement in both camera states.
`/aa safearea on` keeps the complete formation within an eight-pixel screen
margin when combat-camera movement would otherwise push it off-screen.

The `taru` preset is the captured Koruru profile: crown, radius 55, height 35,
speed 0.15, scale 1.15, combat offset -100, idle adjustment +90, and safe-area
off. The compact and cinematic presets change visual presentation without
overwriting character-specific offsets.

## Test preview

`/aa test on` displays a three-orb Fire/Ice/Thunder preview on any job and
persists across addon reloads for visual iteration. `/aa test count <1-3>`
changes the formation size, `/aa test set ...` selects three preview elements,
and `/aa test risk ...` previews every burden-reactive lattice state. Use
`/aa test recast` to replay the 10-second orbital mote, `/aa test deploy ...`
to compare the idle and focused formations, and `/aa test flash [element]` to
replay the authoritative maneuver-confirmation pulse. Test mode is visual-only
and never sends gameplay commands. It overrides live maneuver display until
disabled with `/aa test off`.

## Display behavior

- Buffs 300-307 are reconciled with action packet IDs 141-148.
- Successful action packets remain provisional for up to 2.5 seconds and only
  become orbs after the live maneuver buff count confirms them. Clipped actions
  are discarded instead of creating false 60-second orbs.
- Each active instance gets its own orb, including duplicate maneuvers.
- Packet-observed maneuvers receive exact 60-second timers.
- Maneuvers found on load receive dotted approximate timer rings because the
  original application time is not exposed by the normal buff list.
- Timer rings use sixteen rune-like segments that extinguish with duration,
  aged brass at 15 seconds, and pulsing orange at 5 seconds. Approximate timers
  retain an alternating segment pattern.
- A small brass mote makes one clockwise lap around the full formation during
  the 10-second maneuver recast. It carries a short fading trail, flashes teal
  at twelve o'clock when ready, and then disappears completely. Use
  `/aa recast off` to hide it.
- `crown` is the restrained default: up to three gently moving orbs in a
  symmetric arc. With three active, the centered second orb forms a pronounced
  apex while the two side orbs retain their established vertical placement.
- `orbit` uses a shallow ellipse with depth-based draw order, scale, and opacity.
- Orbs use layered luminous cores, glass highlights, double rims, and subtle
  element-specific animation. `/aa effects off` disables the animated flourish
  while retaining the core, glyph, and timer.
- `/aa icons runes` uses Arcane Automata's restrained original symbols.
  `/aa icons crests` selects a larger silhouette-first set: trident flame,
  six-point ice crystal, spiral gust, faceted mountain, forked bolt, wave-drop,
  eight-ray star, and eclipsed crescent. `/aa icons mechanical` mounts those
  crests inside a faceted gunmetal automaton plate with brass edging, three
  slowly rotating gear teeth, and a counter-rotating inner bearing.
  `/aa icons toggle` cycles through all three. The choice persists per profile
  and every mode is texture-free.
- Crest geometry has restrained element-specific motion: flickering flame tips,
  an ice-tip sparkle, curling wind, settling earth facets, electrical twitch,
  a rolling water line, breathing light rays, and a shifting dark eclipse.
  `/aa effects off` freezes these details without changing the silhouettes.
- Every element has a distinct outer shell: flame fins, crystal facets, wind
  bands, stone plating, a lightning cage, droplet crown, sun rays, or eclipse
  crescents. Identity no longer depends on the center glyph and color alone.
- Duplicate elements resonate: their pulse synchronizes and faint curved energy
  threads carry small motes between matching orbs.
- With three active maneuvers, the invocation lattice connects them in activation
  order with luminous layered threads, a pulsing central seal, and one glowing
  traveling mote. Use
  `/aa lattice off` to hide it. Three identical maneuvers use this lattice in
  place of a second overlapping duplicate-resonance triangle.
- The lattice is deliberately not a second timer. It reflects the worst current
  burden state: a calm teal five-second circuit at `LOW`, an amber circuit of
  about 3.5 seconds at `WARM`, and two-second orange energy at `DANGER`. Only
  `OVERLOAD` uses red, fracturing the orderly circuit into irregular sparks.
  `/aa burden off` leaves the lattice in its calm `LOW` presentation.
- Maneuvers bloom in with an elemental ripple and dissolve when their buff is
  lost. `/aa transitions off` restores immediate appearance and removal.
- When the automaton's entity enters its deployed combat state, `/aa deployfx on`
  tightens the formation by eight percent, slightly compresses its height, and
  brightens and enlarges the orbs. The default `/aa deploystyle seals` places a
  texture-free Aht Urhgan-inspired astrolabe behind each orb: broken aged-brass
  arcs, gold rivets, copper plate rails, restrained turquoise inlay, offset
  counter-rotating workshop geometry, and pronounced gear-like teeth.
  Its perimeter extends beyond both the elemental shell and timer ring so the
  design remains readable. `/aa deploystyle chevrons` restores the paired lock
  markers, now positioned fully outside the orb borders. The state relaxes
  smoothly when the automaton becomes idle. The effect is cosmetic and can be
  disabled with `/aa deployfx off`.
- With the base `/aa style crown`, `/aa deployorbit on` eases the complete
  formation into a shallow Invoker-style carousel only while the automaton is
  deployed, then returns it to the readable crown when the pet becomes idle.
  The elemental crests stay upright while their positions orbit and depth
  scaling identifies the front orb. `/aa orbitspeed 0.06` is the default,
  producing one lap in roughly 16.7 seconds. The recast mote eases to twelve
  o'clock during the carousel and becomes a compact local progress gauge so it
  cannot be confused with the orbiting maneuvers. `/aa deployorbit off` keeps
  the deploy focus and seals but disables the carousel.
- A successful action does not immediately trigger the confirmation flash. The
  addon waits until the corresponding maneuver buff is present, then emits a
  short elemental ring with four pale locking ticks. This distinguishes a
  server-confirmed maneuver from a clipped attempt. Use `/aa confirmflash off`
  to disable it.
- `/aa smoothing 0.12` applies a small camera-anchor damping window; zero turns
  smoothing off, while values up to 0.50 produce progressively softer motion.
- The high-visibility burden halo uses a conservative local estimate: a
  bright brass segmented rail for warm, thicker pulsing orange for danger, and
  fractured red while overloaded. Outward warning ticks keep it visually
  separate from the inner expiration ring. Server-reported chances from
  maneuver action packets remain authoritative when available.
- The default colorblind palette is based on Okabe-Ito hues and every element
  also has distinct rune and crest silhouettes.

The preferred anchor projects the local character's model origin, then applies
the configured screen-space offset. This avoids guessing a race-dependent head
height, which is especially unreliable with the low Tarutaru camera. Invalid,
off-screen, or behind-camera projection is never drawn. When `/aa fallback on`
is enabled, a screen-relative anchor is used if projection cannot be obtained.
Fallback is off by default so unavailable projection hides the display.

With `/aa autohide on` (the default), Arcane Automata also hides during cutscenes,
first-person camera, and whenever the native game interface is hidden. Signature
checks fail open if a future client update makes this state unavailable.

The display clears and hides while zoning, dead, or not on Puppetmaster main job.
It also hides when disabled or when no valid anchor is available.

## HorizonXI approval

Arcane Automata is intentionally visual-only, but HorizonXI requires custom addons to
be reviewed and added to its approved-addon list before use. Publicly host the
source and submit it through the server's current addon-review process before
using it in live play.

## License

Arcane Automata is released under the [MIT License](LICENSE). The bundled
action-packet parser is adapted from tTimers; see
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for its attribution and license.
