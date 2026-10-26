# Reusable 3D demo studio

Use the native **Studio → Graphics** renderer for object demonstrations. A demo
request chooses a saved model revision, camera, light, matte material and bounded
action. It produces an editable scene through the same repository as other
Graphics Studio work. There is no second render environment to rebuild.

This studio uses Clauto's existing Metal, CoreGraphics, CoreText and AVFoundation
stack. Blender is optional for authoring new geometry; these examples need only
the existing app and Python 3.10 or later. The preparation tool uses the standard
library and makes no network requests. No app window opens during preparation.

## Create a demo as an agent

This interface is for local or external coding agents that can prepare files in
the repository. Clauto's current live Claude conversation is text-only and has
no file-editing or render tools. It cannot invoke these commands or directly
import/export a demo through the conversation composer. Preparation and native
file import/export are the supported integration boundary in this increment.

From the repository root:

```sh
python3 scripts/demo_studio.py discover
python3 scripts/demo_studio.py validate studio/examples/kaykit-pan-a.json
python3 scripts/demo_studio.py prepare studio/examples/kaykit-pan-a.json --output /tmp/clauto-demo-prepared
```

The last command returns the exact `import.json` path. In **Studio → Graphics**,
choose **Import prepared 3D demo** and select that file. The native importer creates
the request's deterministic scene identity in the selected project; an exact
repeat reopens its matching saved scene. A conflicting scene with that identity
refuses rather than replacing edits. Change the source request label, rig or
model revision to prepare a distinct scene. Editing geometry in the app clears
the original model attribution instead of attaching that attribution to a cube
or a different OBJ.

Review the actual preview at several exact frames, save the scene, and export
an immutable revision through the existing native export action. The selected
scene identity and exported scene revision stay explicit. The preparation tool
does not publish to a project, promote a cut or alter a current-version pointer.

The source request format is [`studio/request.schema.json`](../studio/request.schema.json).
It contains a catalog `assetID` plus the exact `meshSHA256` returned by discovery.
It has no arbitrary asset path, model URL, script execution or network instruction.
All keys are required and unknown keys refuse. Use a positive portable integer
seed, integer frame count and the literal two-frame step. Source requests and
prepared native requests both reject nonfinite values and duplicate JSON keys.

The native envelope is [`studio/prepared.schema.json`](../studio/prepared.schema.json).
It embeds geometry, the complete rig and frozen provenance. It is capped at one
MiB, 20,000 vertices and 40,000 triangles. The native importer revalidates
coordinates, indices, nondegenerate faces, canvas, model count, provenance and
exact scene ownership. Schema numeric/string limits describe the standardized
portable subset; actual validators additionally enforce UTF-8 byte budgets,
finite values, geometry relationships and `width × height ≤ 8,388,608`.

## Reusable decisions

| Parameter | Choices | Purpose |
| --- | --- | --- |
| Template | `hero`, `inspection`, `overhead` | Consistent camera composition for a subject study, an inspectable object or a top view. |
| Action | `hold`, `turntable`, `rock`, `reveal` | Repeatable bounded motion; geometry remains a declared illustration. |
| Material | `sageClay`, `oatCard`, `walnutIron` | Matte Sage & Oat palette presets; material names are artistic directions. |
| Light | `warmSoft`, `raking` | Reusable key/fill treatment and readable form. |
| Time | `24000/1001`, two-frame step | Native exact frame timing and paired stop-motion poses. |

Discovery returns `templatePresets` with every concrete field. The native hero
preset uses yaw 0.6, pitch 0.45 and a 1.2-radian gentle rock; inspection uses pitch
0.65 and a full-turn turntable; overhead uses yaw 0, pitch 1.25 and a static hold.
All start with sage clay and warm soft lighting. The pan example deliberately
chooses walnut iron. `template` records the chosen preset family; explicit rig
angles, action, material and light govern the actual frame after edits.

The rig centers model bounds, normalizes a bounding sphere and fits the projected
action sweep using 64 intervals (65 sampled angles) plus a conservative margin. Camera framing
remains fixed throughout that action. Source units are recorded independently:
the cartoon pan's units are unspecified and must not be labeled metres.

The default is a crafted matte illustration. It adds no generated paper grain,
photorealistic b-roll, synthetic scanned surface or decorative noise. The
downloaded KayKit gradient atlas is retained for provenance and future decisions;
this demo substitutes the studio palette rather than presenting that atlas as
Katie's scanned artwork. Add her actual cutout/font revisions as separate native
scene layers where needed. A missing physical texture still needs her asset/build
sheet under `CLAUDE.md` and the active style guide.

## Current library and evidence

| Asset ID | Materialized contents | Rights declaration | Verification state at registration |
| --- | --- | --- | --- |
| `kaykit-pan-a` | Original `pan_A.gltf`, `.bin`, atlas PNG, license; adapted geometry JSON (289 vertices, 310 triangles). | Creator's retained CC0 license. Kay Lousberg. | Pinned download/dependency hashes and decoded geometry structure verified. Native import and visual review initially pending; consult current model metadata and task review evidence. |
| `legacy-pan-layer` | Exact copy of the existing Pan Seasoning OBJ and adapted geometry (312 vertices, 496 triangles). | Existing local project; individual authorship/redistribution rights not independently verified. | Original hash retained, deterministic triangulation and Z-up → Y-up conversion verified structurally. Visual/native acceptance recorded separately. |

The KayKit source is the creator's official repository pinned to commit
[`153c8a7535b48237854cb54ff6890679f8c574d1`](https://github.com/KayKit-Game-Assets/KayKit-Restaurant-Bits-1.0/tree/153c8a7535b48237854cb54ff6890679f8c574d1),
`addons/kaykit_restaurant_bits/Assets/gltf/pan_A.gltf`. See its
[creator page](https://kaylousberg.itch.io/restaurant-bits) and the retained
[`LICENSE.txt`](../studio/models/kaykit-pan-a/LICENSE.txt). The original binary and
atlas are part of the frozen source set. The license covers asset use, while
scientific meaning and Katie's visual acceptance remain separate review states.
No paid Blender-source tier or new account is required.

The earlier Pan Seasoning scene was an ad hoc local mesh/render script with a
faceted pan, conceptual coating section, bespoke camera and bespoke lighting.
The legacy example preserves that actual subject matter. The curated pan example
uses the repeatable native rigs and a more resolved modeled silhouette. Compare
actual rendered pixels and motion before approving either for a video; the
library's presence or a passing parser test does not establish visual quality.

## Add a future model once

1. Find the creator/official source and license. Record a fixed revision URL,
   creator, declared units and up axis. Download into a new catalog asset folder;
   keep original geometry, texture dependencies and license. Researching a source
   is separate from downloading it, adapting it and verifying it.
2. For a static glTF with one identity-transform mesh node and ordinary indexed
   triangles, run:

   ```sh
   python3 scripts/demo_studio.py adapt-gltf studio/models/your-asset/source.gltf
   ```

   This returns geometry, a normalized serialization hash and dependency hashes
   as JSON. It reads simple sibling file names only. It refuses remote/data URIs,
   missing dependencies, unapplied transforms, animation, skins, sparse accessors,
   unsupported extensions and compressed geometry. Export a baked static object
   with a supported topology first when necessary; optional Blender authoring is
   separate from the app's render contract. No material or transform is silently
   assumed to be physically accurate.
3. Save the returned `mesh` using the tool's canonical serialization to
   `mesh.json`. Register `metadata.json` following the existing model: exact mesh
   hash; creator/source/license/modifications/rights status; all retained source
   file hashes, including adapted mesh and license; full license text;
   normalization notes and explicit verification states. `cc0` and `licensed`
   declarations require nonempty license text and a source URL. Unknown local
   rights remain `local-unverified`.
4. Run discovery and prepare an example. The tool checks every pinned file before
   producing an envelope. Import into a disposable native test project, inspect
   actual pixels and record the producer/environment and review artifact. Keep
   `nativeImportVerified: false` and `visualReview: pending` until observed.

The source models are never modified in place during preparation. Native imports
freeze source hashes, license text and adaptation descriptions in editable scene
snapshots and immutable revision metadata. Original catalog files remain in the
library; a hash pin establishes identity rather than independently proving rights
or constituting a backup of every original dependency inside a project export.

## Preview, render and export contract

Preparation returns a content-addressed folder containing canonical `request.json`,
self-contained `import.json`, and `prepared.json`. `prepared.json` means **prepared**;
its `renderVerified` value is false. The identity hashes canonical request bytes,
actual mesh, frozen provenance and preparation tool version. Later documentary
verification notes do not silently change an existing scene's identity.

Repeated preparation verifies completed bytes and retains the same files. A
matching interrupted `.partial` prefix resumes to the exact expected bytes.
Conflicting bytes, changed source hashes or unknown partial contents stop with
an actionable message; they are never overwritten or treated as complete.
Concurrent preparations serialize the same recipe. Test output roots are
explicit and disposable; no configured media path is discovered or created.

Native preview is a requested exact frame of the same saved scene model used by
export. Rendering/export follows [GRAPHICS_STUDIO.md](../Clauto%20Editor/docs/GRAPHICS_STUDIO.md):
alpha movie, first/last PNGs, exact decode proof, hashes, copied scene/provenance,
and FCPXML under a new immutable project scene revision. Existing revision and
current-pointer safeguards remain in force. Interrupted native exports retain
incomplete evidence rather than becoming admitted revisions. Use a new export
revision for a later scene edit.

FCPXML retains a separately placeable/retimeable connected graphic movie. That
movie is not native editable 3D geometry or individual Final Cut text primitives.
Scene/model/font/cutout edits remain in Clauto and can be re-exported. Do not
describe the rendered movie as fully unflattened scene primitives.

## Verify

```sh
python3 -m unittest discover -s tests -p test_demo_studio.py -v
```

The dependency-free focused suite covers model/source substitution refusal,
strict input rules, exact glTF adaptation, unchanged source identity after review
notes, deterministic bytes across output roots, eight concurrent repeat calls,
partial-prefix resume, foreign/corrupt output refusal, symlinks and explicit
separation of preparation versus render verification. Native tests/render proof
cover the actual app producer. Run those under the coordinator's available
compute window; a Python preparation test does not exercise Metal, movie decode,
Final Cut import, NAS behavior or user interaction.
