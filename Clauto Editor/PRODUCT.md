# Clauto native app

Clauto is a local macOS front door to the editing engine in this repository. A person
brings footage, describes the video, reviews a cut, and saves change requests. The
mechanism is **brief + local media + conversation → a named, revisable cut**.

The interface is for someone comfortable with Finder and drag and drop. It makes
project state, missing files, review gates, and saved versions understandable without
requiring a command line. Final Cut remains the finishing editor; Clauto does not add
a timeline editor.

The implemented app owns project selection and creation, the brief, file intake and
roles, local pipeline progress, graphic-plan approval, saved cuts, time-bound feedback,
and separate derivative exports. Existing model and service callbacks remain the
source of truth. The conversation composer saves and streams explicitly submitted
text through an existing client, with guided account connection and queued steering.
Media, transcripts, frame notes and earlier local requests are not automatically
sent. Conversational cut changes and longer idle-packet jobs remain unfinished.
Workspace setup checks installed tools and folders; complete engine/client
installation remains future work. Voice feedback and region dictation guide their
embedded local speech setup. Debug builds do not start Sparkle checks.

Original media is referenced or copied according to the user's choice and is never
modified. Scientific claims and graphic plans require human review. A failed run
keeps the previous cut available. The engine's Sage & Oat video style and its rules
remain governed by `../taste_principles.md` and `../style_guide.md`; the app identity
is a separate design system.

Nathan's app identity requirements are binding: authored geometry and typography,
no SF Symbols, and no visible default Apple app controls. Native file dialogs,
menus, text editing behavior, and window semantics remain available. The existing
OFL Work Sans font is bundled with its existing license; no new font or software
license is introduced.

The app UI's durable design decisions are in [DESIGN.md](DESIGN.md). Detailed
product and engineering plans remain in [docs/PRODUCT.md](docs/PRODUCT.md) and
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

Cutout Studio adds a project-local original/mask/revision workflow with local subject selection, manual brush corrections, undo/redo, feathered transparency and PNG output. It retains original encoded bytes, source/model/parameter hashes and earlier revisions. The bounded source/core increment does not establish actual Vision/native GUI acceptance or composition of its asset into a saved cut; see docs/CUTOUT_STUDIO.md.
