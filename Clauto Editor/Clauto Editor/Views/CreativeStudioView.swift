import SwiftUI

struct CreativeStudioView: View {
    @Bindable var store: EditorStore
    let project: Project
    @State private var section = "Templates"
    var body: some View {
        VStack(alignment: .leading,spacing: 0) {
            HStack {
                ClautoChoice(title: "Creative studio",selection: $section,options: [("Templates","Templates"),("Cutouts","Cutouts"),("Fonts","Fonts"),("Graphics","Graphics"),("Handwriting","Handwriting")])
                Spacer()
            }.padding(.horizontal,28).padding(.vertical,14)
            ClautoRule()
            if section == "Templates" {
                ScrollView {
                    VStack(alignment: .leading,spacing: 22) {
                        Text("Start with something useful").font(ClautoDesign.heading)
                        Text("Editable titles, captions and graphics. Every template uses this project's picture shape; source footage and saved cuts stay untouched.").font(ClautoDesign.body)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 260),spacing: 18)],spacing: 18) {
                            ForEach(StudioStarter.allCases) { starter in
                                Button {
                                    store.graphicStudio(for: project).create(template: starter);section = "Graphics"
                                } label: {
                                    VStack(alignment: .leading,spacing: 12) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: 12).fill(ClautoDesign.soft)
                                            VStack(spacing: 8) {
                                                Text(starter == .chapter ? "01":starter.title).font(ClautoDesign.type(24,weight: .semibold))
                                                Rectangle().fill(ClautoDesign.ink.opacity(0.3)).frame(width: 75,height: 2)
                                                Text(starter == .title ? project.manifest.name:starter.detail).font(ClautoDesign.caption).multilineTextAlignment(.center).lineLimit(2)
                                            }.padding(18)
                                        }.frame(height: 145)
                                        Text(starter.title).font(ClautoDesign.type(16,weight: .semibold))
                                        Text(starter.detail).font(ClautoDesign.caption)
                                        Text("Use template →").font(ClautoDesign.caption)
                                    }.padding(16).frame(maxWidth: .infinity,alignment: .leading)
                                }.buttonStyle(ClautoInlineButtonStyle()).disabled(store.graphicStudio(for: project).hasPendingWork)
                                    .accessibilityIdentifier("studioStarter-"+starter.id)
                            }
                        }
                        Text("Your cutouts, custom fonts and existing scenes are available in the tools above.").font(ClautoDesign.caption)
                    }.padding(28)
                }
            }
            else if section == "Handwriting" { HandwritingStudioView(controller: store.handwritingStudio(for: project)) }
            else if section == "Graphics" { GraphicStudioView(controller: store.graphicStudio(for: project)) }
            else if section == "Fonts" { FontStudioView(controller: store.fontStudio(for: project)) }
            else { CutoutStudioView(controller: store.cutoutStudio(for: project)) }
        }
    }
}
