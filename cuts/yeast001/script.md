# Yeast 001 — the script, as cut

**13:04 · 118 picks · 23.976p** · rough cut at `build/roughcut/yeast001.roughcut.fcpxml`

This is the read-back of the **assembled cut** — chosen from the word-level transcripts of all
fourteen a-cam clips (46 minutes), then punctuated and paragraphed by hand. It is what the video
says, in order. Where this page and the audio disagree, the audio wins; the machine read-back of
the rendered cut is in `read-back.txt`. Where WhisperX had folded a false start into the word after
it, the in-point was re-measured off the audio with `silencedetect` and set exactly — see
`make_picks.py`, `exact_start`.

The previous cut (`cuts/intro001/`) was built from the June 9 tapes. **None of that footage is
in this cut** — different top, different hair, different framing; it cannot intercut. Everything
here is from the June 16 reshoot in `footage/a-cam/`, which was shot against that cut's build
sheet and covers all of it except the three pickups listed at the end.

| | |
|---|---|
| Source | 46:15 across 14 clips |
| Cut | 13:04 (28%) |
| From MVI_0040 | 5:28 — access and need, budding, chemistry, temperature, sugar |
| From MVI_0038 | 2:36 — the environment, Pasteur, the one bug, the close |
| From MVI_0045 | 2:00 — the jars |
| From MVI_0037 | 1:06 — yeast is old, brewers and bakers |
| From MVI_0041 | 1:01 — the Pasteur aside |
| From MVI_0042, 0036, 0043 | 0:50 — sourdough aside, the intro line, the two VO lines |
| From MVI_0032–0035, 0039, 0044 | nothing — see "What was left out" |
| Two setups | **Table** (0036–0039): intro, history, Pasteur, one bug, close. **Kitchen** (0040–0045): the asides, the jars, everything from 7:25 on. |
| Music | *Twin Lakes* under the cold open, out by 0:30. *Two Big Reasons* from 12:32, ending on the last frame. Both 16 dB under her, measured 200 Hz–4 kHz. |
| Framing | Two static punch-ins (1.08×) hiding jump cuts where both neighbours run ≥ 10 s; four slow pushes (≤ 1.06×) under emphasised lines. All are `adjust-transform`s on the clip, not renders. |
| Grade | `assets/luts/yeast001-grade.cube` on every a-cam clip, plus a soft-light lift on her face (preview only). Build sheet §G has the numbers and the Final Cut equivalent. |
| Pace | Join pads 80/120 ms; every pause over 0.7 s inside a take trimmed to a 250 ms breath — 49 of them, 48 s. Never below the 120 ms floor [S-002]. |

**The read-back stands at four flags, all accounted for.** Three "repeats" at 0:22, 1:30 and
7:28 are her own parallel phrasing (*we've found it in… we have found it in…*; *if it's a dud
batch… if they have a successful batch…*; *why do we have so many names… so many formats*),
not two takes. The fourth is the last line ending without a full stop. Eight false starts that
earlier read-backs *did* catch are cut out at measured silences; none of them were visible in
the transcripts. The pause-tightening pass was diffed word-for-word against the previous
read-back: nothing lost but the two paragraphs cut on purpose and one "the, the" stammer.

Timecodes are timeline positions. **⚠︎** marks a decision or a check needed before lock; each
one is in `build-sheet.md` with a fix. **Picture** says what is on screen and what is still
wanted there.

---

## Cold open — 0:00

> This is yeast bubbling in action.
>
> And this is me, way too excited about yeast.
>
> You don't actually need sugar to make your yeast grow. You just need time.
>
> Hi, I'm Katie. I'm a food scientist, and this is my deep dive into yeast.

The hook now names a mistake inside six seconds — §9 asked for that and the June 9 cut didn't
have it. "You just need time" is the line the whole sugar section at 11:42 pays off.

**Picture.** *Shot 1* is the starter glass from `Best Yeast Broll`, bubbles breaking at the
surface. *Shot 2* is Katie dancing, both arms up (`Katie Dancing` @ 0:57) — the clip ends with
her walking up to the lens grinning (1:04–1:07), which is the alternate if the dancing reads as
too much. *Shot 3* is her in the kitchen, with a slow push to 1.05×. *Shot 4* is the table.

**⚠︎ The wave.** The first seconds of MVI_0032 are her walking in and sitting down; there is a
small hand-to-camera at ~0:08 but it is not a wave. The wave that was under "way too excited" in
the June 9 cut is in MVI_0016, which doesn't match this shoot. If you want a wave, the dancing
clip at 0:56–1:00 is the nearest thing.

**Graphic.** The title card lands under "my deep dive into yeast" — the first graphic inside 30 s.
Rendered as a **placeholder** (flat bone, Kalam): see build sheet §A.

---

## 1. Yeast is old — 0:13

> Yeast is really old. We've had it around for at least a few thousand years. We've found it in
> archaeological records in Egypt. We have found it in archaeological records in parts of Asia
> and in Europe.
>
> It's around. It's in our environment. It grows on grapes.
>
> We know that the yeast is in the air around all these ancient people, and so it is just
> falling into their food — or it's on the grapes that they're smashing up to make wine. It is
> being pulled in from the environment. It's not being inoculated. It's not being pushed into
> the food by the bakers themselves, until they figure out kind of what's going on: that you
> need a little bit of something to make something else.
>
> You get the brewers that are taking grapes and grains and turning it into wine and beer and
> mead. And they're producing these fermenting, bubbly batches of goodness that they like, and
> they are taking it and they're passing it on to their friends that are making doughs. Those
> bakers are getting bubbly batches that are making dough that rises, and are different than
> flat breads, and it's being passed back and forth, back and forth.
>
> With the passing back and forth, you get selective breeding going on. They may not know what
> they're breeding, but they're being selective about it. If it's a dud batch, they're not
> passing it on to their friend. If they have a successful batch, they're passing it on to their
> friend — and the genes of the yeast are being selected for the ones that ferment and make
> alcohol and raise bread and do lots of things that these ancient people wanted.

This is the version without a date. She recorded "3000 BC, 2000 BC" (MVI_0033) and "about
3,000 years ago" (June 9) and neither is in the cut — "at least a few thousand years" is both
true and hers. The timeline card should be as vague as the line under it.

**Cut in the second pass, for pace:** *"The details are a little hazy, because it's hard to
extract the DNA and prove that it's yeast with everything else that's mixed into it. That's my
understanding. So we just know it's old."* (MVI_0036 @ 1:02, 13 s) and *"So it's natural that
ancient people would have just stumbled upon it"* (MVI_0037 @ 0:55, 6 s). Both charming, both
slow, and both sat in the first forty seconds; the second is said again in the next paragraph
anyway. If the hazy-DNA line is wanted back, it fits exactly where it was.

**Picture.** Table, one setup, 1:30 unbroken apart from the cuts between takes. It carries four
graphics and one piece of b-roll:

- **Timeline card** at 0:18 — Egypt · Asia · Europe as a spread, no dates, torn edge.
- **Wild yeast on grapes** at 0:27 — a macro of the bloom on a dark grape. She names it; it is
  the one Storyblocks shot worth buying if it can't be shot.
- **The exchange** at 0:52 — the brewer's jar passed to the baker and back. Cardboard, on 2s.
- **Key term** at 1:19 — *Selective breeding*.
- **✗ / ✓** at 1:29 — the dud batch pushed out of frame, the good batch handed on (§6.6).

---

## 2. Louis Pasteur — 1:45

> It wasn't until we meet Louis Pasteur that we have an inkling of what's making one successful
> batch work, and what's being passed on between these bakers and brewers. He has a gooseneck
> experiment, and disproves spontaneous generation, and says there are microbes — little bugs
> that we can't see, all around the world.
>
> If you don't know about the Louis Pasteur experiment: what he does is he takes a glass bulb and
> stretches out a neck on it, that is open over here, but it has a gooseneck shape. And he heats
> it up to kill off any bacteria that's on the inside, with some food that he has cooked, that
> he has put inside of this gooseneck bottle.
>
> And so if there's any truth to spontaneous generation, the food will just break down. There
> will be no problem with it doing what food has always done. But if the food breaks down because
> of germ theory — what he was thinking of is: germs can't get in through the gooseneck bottle.
> It falls down. It gets stuck in the downspout, right here. So nothing will happen to the food.
> It won't break down. It won't do anything. And that's what happens.
>
> And so Louis Pasteur proves that there is no spontaneous generation — that there is something
> in the air: bacteria, yeast, living organisms that are getting into our food and making changes.

**⚠︎ Meyen is out.** The take that names him — *"After Louis Pasteur, we get to 1838, and Franz
Julius Ferdinand Mayen discovers yeast, Saccharomyces cerevisiae specifically"* (MVI_0038 @ 5:51)
— is chronologically backwards: the swan-neck work is 1859–61, so 1838 is *before* Pasteur, not
after. The spelling is also still "Mayen" (it is Meyen), which was D2 last time. Rather than put
a wrong date on a name card, the cut goes from Pasteur's microbes straight to "we meet our
*Saccharomyces cerevisiae*", which holds together without him. (The take begins "And so we get
Sac— we meet our…"; the in-point is after the stumble.) **One-line pickup** if you
want the name back: *"Twenty years before Pasteur's flask, in 1838, Meyen had already given it a
name."* Escalated as D1.

**⚠︎** "because of germ, germ theory" — the stumble is in the cut because the sentence it starts
is the one that explains the experiment. If it bothers you, the take at MVI_0041 2:01 has the
same sentence without the stumble but trails off afterwards. Two false starts in this chapter
are cut at measured silences: "…and that's what happens [and this is why, what, Louis—]" and
"[And with the—] And with the discovery" in the next chapter.

**Picture.** The chapter moves from the table to the **kitchen** at 2:07 for the aside ("If you
don't know about…") and back to the table at 3:43. That setup change is doing the work of a
second camera, and it's motivated: the aside is an aside.

- **Pasteur portrait** at 1:47 — the Nadar photograph (public domain), placed in the left
  column beside her, never over her face. Rendered and in the timeline.
- **The swan-neck flask** at 2:11 — the Wellcome photograph (CC BY 4.0), same placement, on
  screen for 10 s while she describes the neck. It has a black background, which §4.1 doesn't
  allow in a *graphic* — it is here as a reference so the shot can be judged, and the flask
  should be **drawn or built as a cutout**: it is the single most drawable object in the video.
- **Dust in the bend** at 2:47 — a rust mark settling in the downspout, on the flask drawing,
  on "it gets stuck in the downspout right here". She points at something off-frame on that
  line; the graphic is what she's pointing at.

---

## 3. One bug — 3:09

> We meet our *Saccharomyces cerevisiae*. And this is the most common form of yeast that
> we use today. There are other yeasts that are used in sourdoughs, but for the most part, when
> you get to industrial bakers, and you get to at-home bakers, and you get to brewers — they're
> all using the same little bug: *Saccharomyces cerevisiae*.
>
> *Saccharomyces cerevisiae* is a yeast, which is a member of the fungi family. It's a
> single-cell organism that lives and thrives and grows in fertile environments.
>
> Now, an aside about sourdough. Sourdough is also using yeast. Most sourdoughs are using
> *Saccharomyces cerevisiae*, but you'll find in other sourdoughs that there are lots of other
> different types of yeast involved. It's also using a bacteria that produces lactic acid. And
> so I'm setting sourdough to the side so we could specifically talk about yeast — but sourdough
> is using yeast. It is using other forms of yeast that could do the same thing as
> *Saccharomyces cerevisiae*, but *Saccharomyces cerevisiae* is specifically known for producing
> repeatable results that do what we want it to do, which is why we use it so much.
>
> And with the discovery of *Saccharomyces cerevisiae*, we move from always needing to have a
> sourdough-based model — where we have a mother dough, a mother ferment, maintaining our yeast
> that we pull from to make our doughs — to being able to have on hand just the yeast, and using
> that, and introducing it into our dough at measured amounts that we want. And our way of baking
> and our way of brewing changes, because we can be a little bit more intentional with how we
> are baking and how we are brewing, with being able to measure out the organism that we're
> introducing into our batches.
>
> *Saccharomyces cerevisiae* is used all over the industries, from alcohol industries to our
> baking industries — from the big brewers, the big wine makers, the big bakers, to the at-home
> enthusiasts.

**Picture.** Table → kitchen (the sourdough aside, 3:46–4:28) → table. The 4:28–5:52 stretch is
the longest unbroken talking head in the cut and has one graphic in it; it wants the
**comparison card** at 4:37 — a mother-ferment jar on the left, a measured packet on the right
(§6.6, two items, no more). At 5:52 the insert is the wide of the dry-yeast jars (MVI_0026).

- **Name card** at 3:10 — *Saccharomyces cerevisiae*. This is the recurring card: it comes back
  identically at 6:49 and is the first word of the close. Set it once.
- **Micrograph** at 3:35 — the SEM of *S. cerevisiae* (CC BY 3.0), left column. Rendered and in
  the timeline. The fungus line carries a 1.08× punch-in so the cut into it from the long take
  before doesn't jump.

---

## 4. What's on the shelf — 5:25

> Right here, off camera, I have a couple examples of yeast that you might find when you're out
> and about looking to buy yeast.
>
> I have some active dry yeast that they actually pre-seeded with sugar. You don't actually need
> the sugar in there.
>
> I have instant yeast right here. It's a little bit smaller, and so it takes a little bit less
> for the water to get in and get the yeast going and active and ready to be added into a dough.
>
> I also have a fresh yeast right here. It's ready to go. It's very fragrant. It can just be
> added straight into a dough. It does have a shorter shelf life. It's more likely to eat through
> the food source that it has built in with it when it is sold. And so it doesn't last as long
> on the shelf as, say, the active dry and the instant — which the producers of the active dry
> and instant have dried it out and made the yeast cells dormant, and less likely to die off.
>
> I even have this yeast packet right here that is marketed as for mead. And when you look at
> it, in its ingredients, it is just *Saccharomyces cerevisiae*. All of these things that I just
> showed you are the same. All of these are the same little bug, the same microbe, the same
> yeast fungi — they're all *Saccharomyces cerevisiae*.
>
> It's a different way of trying to get it into the hands of those who are looking for it.
> Because when you're a brewer, you might be looking for brewer's yeast, because you know —
> that's what I'm doing, that's what I'm looking for. But if you went to the store and bought
> baking yeast, it would be the same thing. But it might not click that that is what you're
> looking for.
>
> And so someone with a marketing degree, with a business degree, is saying: hey, let me sell to
> you. I know what you need. It's this. But it's really all just the same *Saccharomyces
> cerevisiae*.

**⚠︎** "You don't actually need the sugar in there," ends on a comma — the sentence continues
into a triple restart on tape ("but it would just be a… it would just be a…") and is cut before
it. Listen to whether the rise at the end reads as a cut. The alternative is to carry on to
"…and get started" at MVI_0045 0:57, stumbles and all.

**⚠︎** She says "instant dry yeast" at 0:30 and "instant yeast" again at 0:59 in MVI_0045; the
first one is dropped, so the order on screen is active dry → instant → fresh → mead.

**Picture — the insert sequence.** She says "off camera" and means it: the jars are below
frame. The b-roll folder has exactly these shots, and they are cut in as split edits:

| TC | Insert | Clip |
|---|---|---|
| 5:32 | jar of dry yeast, close | `MVI_0027` @ 6 s, whole pick |
| 5:39 | shallow jar, fine granules | `MVI_0028` @ 1.5 s, then @ 3.4 s for 5 s after the join |
| 5:51 | fresh yeast cube in the glass | `MVI_0031` @ 1 s, 8 s |
| 6:30 | the mead packet with the jars | `MVI_0029` @ 2 s, 10 s |

Label legibility is the whole point of 6:30 — check the "Mead Yeast" packet reads at 1080p.
"It's really all just the same" (7:14) carries a push to 1.06×. The instant-yeast line is two picks (5:39, 5:41): the take has "It's a little bit
more… It's a little bit smaller" and the false start is cut out at the measured silence.

---

## 5. Access and need — 7:25

> Why do we have so many different names for it? Why do we have so many different formats for
> it? The answer is access and need.
>
> You have industrial bakers who don't necessarily want to take the time to reactivate something
> from being dormant — that want to just use it and move on and get going with their timelines.
> And you have the at-home baker in the middle of a farm in Kansas that needs something every
> once in a while, and doesn't want to have to drive two hours back and forth to a grocery store
> every couple days to get fresh yeast. They need something on hand that they can keep, that
> won't die off on them as frequently.
>
> So you have fresh yeast and dry yeast, and you have active dry and instant.
>
> Why doesn't the large baker use the instant yeast? It doesn't need to be reactivated, it
> doesn't take as long to be reactivated, and it's always on hand. But in the processing of the
> active dry yeast and the instant yeast, the yeast gets a little damaged, and it can show up in
> the elasticity of the gluten development. It can shear it a little bit, and it helps dry out
> the bread a little bit faster — because of this chemical release called glutathione.
> Glutathione will get into the gluten network and have it break a little bit easier, and it
> will help the starch release the water a little faster. So you have more of a shorter texture
> that you might get more of in a sandwich bread, and have it dry out faster.
>
> So having a fresh yeast allows these bakers to have a product that does what they want it to
> do. It's consistent. It doesn't dry out. And to be honest, an at-home baker might not care. You
> might not notice. They consume the bread within a couple days, because they're only making one
> loaf at a time.
>
> So it's about what's available, and what you can use, and what you can find — and what other
> things are going on in your life, for what matters. Because it might not be worth driving a
> couple hours to a grocery store to get something to have a bread that's a little bit stretchier
> that lasts a day longer.

**⚠︎** The glutathione mechanism (E3) and "it might help dry, it helps dry out" at 8:29, which
is a self-correction left in because the clean take doesn't exist.

**Picture.** Kitchen from here to the end. Graphics: **key term** *Access and need* at 7:30; the
**two bakers** card at 7:43 (a bakery and a farmhouse an hour from a shop, §6.6); **key term**
*Glutathione* at 8:38; the **gluten matrix** at 8:43 — long strands, then strands cut short, the
clearest before/after in the video. B-roll wanted at 9:00: a cut loaf, stretchy crumb against
short crumb.

---

## 6. Budding — 9:30

> If we have so many of the same little *Saccharomyces cerevisiae*, how do we reproduce it?
> What's going on?
>
> So you have a mother cell that grows, and buds on itself a daughter cell. And when that
> daughter cell is big and identical to the mother cell, it uses mitosis and splits into two
> cells.
>
> The yeast will continue to grow and reproduce itself when it's in an environment that has lots
> of nutrients for it. And those nutrients are sugars and starches. It breaks down starch into
> sugar.

**Graphic — the budding cycle** at 10:39. Mother, bud, daughter, split. The molecular kit's
first real job; the split should land on "splits into two cells", not on a timer. "The yeast
will continue" carries a 1.08× punch-in, and starts at a measured silence: the ten seconds before "The yeast
will continue" on tape are a stumble ("It grows, does this, this, the…") that WhisperX had folded
into a single word.

---

## 7. What it eats — 10:01

> So starch itself will break — flour itself uses an alpha amylase and a beta amylase to break
> those starches down into sugars that the yeast can digest. The yeast will start digesting
> sucrose with invertase, and break that down, and use that energy for itself. The yeast will
> use simple sugars and break it down with the enzyme zymase into CO₂ and alcohols.
>
> And the CO₂ and the alcohol are the byproducts that we're looking for as humans — either in
> alcohol production, or in helping our bread rise with the CO₂, giving the gas that we will
> eventually bake off.

**⚠︎ Chemistry, escalated (E2).** This is better than the June 9 version — amylases now break
starch "into sugars", not into sucrose — but the chain as spoken is still *starch → amylases →
sugars; sucrose → invertase; simple sugars → zymase → CO₂ + alcohol*, and she restarts five
times across MVI_0040 6:40–7:33 getting there. She is reading. It cuts together, but **do not
build the pathway diagram until she has signed the chain**, because a diagram hardens it.

**Picture.** Pathway graphic at 10:03 and 10:25, blocked on E2. B-roll at 10:37 — dough rising,
oven spring — Storyblocks if it can't be shot.

---

## 8. Temperature — 10:43

> Yeast is looking for a right environment for it to thrive and to grow, and that environment
> has lots of sugars and starches, and is in a temperature between 50 degrees, where it kind of
> shuts down and goes dormant, and 140 degrees, when it's completely killed off.
>
> There's a nice sweet spot right in the middle — about 93 degrees Fahrenheit, and 100 plus a
> couple degrees Fahrenheit. And in that sweet temperature spot, it will grow and thrive. And
> that is the temperature we generally want our bread to be sitting at, to kind of reproduce and
> proof at the rate that we want it.

**⚠︎ Numbers, escalated (E1).** 50 °F / 93–102 °F / 140 °F here; the June 9 tape said 54 °F /
"just over 100" / 140 °F. Two shoots, two sets of numbers; the gauge can carry only one.

**⚠︎** "between 50 … degrees" — there is a 1.6 s pause after "between" on tape (she loses the
thread and picks it up). The take is left whole rather than cut across the pause; the read-back
hears "between … 50 degrees" correctly. Worth a listen at 10:53 all the same.

**Graphic — the gauge** at 11:57. One strip: dormant at the bottom, the sweet band, the kill
line. Blocked on E1.

---

## 9. Faster and slower — 11:24

> So when we add salt and fat and other spices to our bread doughs, what we're doing is we're
> putting items in the way of the yeast and its food. And so it's slowing down the process in
> which the yeast can digest the sugars that it wants for growing, and that will then slow our
> proving time. The availability of sugar will speed up the proofing time.
>
> This is why in active dry yeast they recommend that you add a little bit of sugar, to kind of
> start the yeast up and going and getting it bubbling. You don't have to actually do that. You
> can just let it sit a little longer.
>
> Yeast itself just really wants flour and water, and you can do that sometimes by getting a
> pre-ferment. This is what I have going right here, and it's already starting to bubble up —
> and it's just flour and water and yeast, and the yeast is in a happy spot.
>
> Adding sugar does speed it up, but then you end up with a sweeter dough. And if that is not
> the final product that you want, you do not actually need to add sugar to your dough to get
> the yeast to grow.
>
> The other byproduct of starting with maybe a pre-ferment — a pre-ferment is basically a
> different version of a sourdough. It lets the yeast get going and multiply, and kind of
> creates an environment that's easier to add to your dough later. It also, as the yeast breaks
> down the flour, creates a more complex flavor that might be what you want in your end product.

This is where the hook pays off. "You just need time" at 0:06 → "you don't have to actually do
that, you can just let it sit a little longer" at 11:45 → "you do not actually need to add
sugar" at 12:17, which carries a push to 1.05×.

**Picture.** Inserts from the b-roll: the tall glass of pre-ferment bubbling at 11:58 (`MVI_0023`
@ 14 s, 9 s — she's holding the real jar on that line) and the surface bubbles close at 12:25
(`MVI_0025` @ 20 s, 7 s). Wanted: fat, salt and spice going into a bowl at 11:32; and the
**failure-then-fix** shot this whole section is asking for — two doughs, same flour, same
clock, one with sugar, one without. Locked-off timelapse. It proves in six seconds what she
spends a minute and a half explaining.

---

## 10. The same little bug — 12:48

> *Saccharomyces cerevisiae* is the same little guy that is being used all over the food
> industry — from the big yeast cakes that you have in the factories, to the little packets that
> we buy at the store for at-home baking.

Back at the table for the close, with *Two Big Reasons* underneath from 12:32 landing its
ending on the last frame, and a slow push to 1.04×. It is the takeaway.

**⚠︎ The button is missing, and it's the camera's fault.** The take goes on: *"It's the same
little bug, Saccharomyces cerevisiae"* — and MVI_0038 stops at 12:07.81, the body's 12-minute
clip limit, with "cerevisiae" half said. The read-back hears "it's the same little bug
saccharomy—". So the cut ends on "for at-home baking", which is a complete thought, and the
last line is a pickup (D1) — the same sentence, said once more, is all it needs. **There is also
still no next action** — §9 wants one, under 20 seconds, and nothing on either tape says it.

---

## What was left out, and why

**The Meyen line** (MVI_0038 5:51) — see chapter 2. Wrong date order; pickup offered.

**MVI_0032 (1:10), MVI_0033 (2:07), MVI_0034 (0:41), MVI_0035 (0:42)** — setup, singing
"let's talk about yeast", and three earlier passes at "yeast is old" that MVI_0037 does better.
0034/0035 have the "tombs of pharaohs" phrasing if it's wanted; the cut uses "Egypt".

**MVI_0039 (1:50)** — the table version of "why so many names". The cut uses the kitchen version
(MVI_0040) because everything after it is kitchen, and a table → kitchen → kitchen → kitchen run
is one setup change instead of two.

**MVI_0044 (0:16)** — one false start at the jars.

**The "spontaneous generation was magic" passage** (MVI_0038 2:49–2:47) — four attempts, none
complete. The Pasteur aside defines it by showing the experiment instead.

**"And the CO₂ and the alcohol … to help our alcohol grow"** (MVI_0040 7:38) — the first of two
takes, with the slip. The second is in.

**Every restart.** She restarts a lot — it's normal and it's what the take notes in the FCPXML
are for: every join carries a marker saying which take it is and why.

**Stumbles left in.** The read-back hears her restarts inside long takes — "there are other,
there are other yeasts"; "they're all using this, they're all using the same little bug"; "you
can just add it straight into— it can just be added straight into a dough"; "it's more, it's more
likely"; "on them— on the shelf"; "which had— which the producers"; "because of germ, germ
theory"; "in the, in the downspout". Each is a few hundred milliseconds inside a take that is
otherwise the best one. Cutting them out means a jump cut mid-sentence; they are left for you
to decide on in the timeline, where each one is a marker away.

**Three pickups, not recorded on either shoot:** the close's last line and a next action (D1);
the Meyen sentence in the right order (D2); and an outro ask of any kind. Everything else on
the June 9 build sheet is covered.
